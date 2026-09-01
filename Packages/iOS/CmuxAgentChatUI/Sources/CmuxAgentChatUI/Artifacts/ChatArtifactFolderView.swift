import CMUXMobileCore
import CmuxAgentChat
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ChatArtifactFolderView: View {
    private struct LoadIdentity: Hashable {
        let path: String
        let sourceIdentity: String?
    }

    let path: String
    let scope: ChatArtifactViewerScope
    let onDone: () -> Void

    @Environment(\.chatArtifactLoader) private var loader
    @State private var state: LoadState = .loading
    @State private var loadAttempt = UUID()

    var body: some View {
        content
            .task(id: LoadIdentity(path: path, sourceIdentity: loader.sourceIdentity)) {
                await load()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .listing(let listing):
            VStack(spacing: 0) {
                breadcrumb
                Divider()
                if listing.entries.isEmpty {
                    VStack(spacing: 8) {
                        Text(String(localized: "chat.artifact.folder.empty", defaultValue: "No items", bundle: .module))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if listing.isIncomplete || listing.isTruncated {
                            Text(String(
                                localized: "chat.artifact.folder.incomplete_empty",
                                defaultValue: "This folder could not be listed completely. Tap Retry to try again.",
                                bundle: .module
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        } else {
                            Text(String(
                                localized: "chat.artifact.folder.empty_refresh",
                                defaultValue: "New items may appear after a refresh.",
                                bundle: .module
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        }
                        Button {
                            Task { await load() }
                        } label: {
                            Label(
                                String(localized: "chat.artifact.retry", defaultValue: "Retry", bundle: .module),
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            ForEach(listing.entries) { entry in
                                NavigationLink {
                                    let route = childRoute(for: entry)
                                    ChatArtifactViewerDestination(
                                        path: route.path,
                                        scope: route.scope,
                                        onDone: onDone
                                    )
                                    .environment(\.chatArtifactLoader, route.loader)
                                } label: {
                                    rowLabel(entry)
                                }
                            }
                        } footer: {
                            if listing.isTruncated {
                                Text(String(
                                    localized: "chat.artifact.folder.showing_first_500",
                                    defaultValue: "Showing first 500 items",
                                    bundle: .module
                                ))
                            }
                            if listing.isIncomplete {
                                Text(String(
                                    localized: "chat.artifact.folder.changed_while_loading",
                                    defaultValue: "Some items changed while loading. Pull to refresh.",
                                    bundle: .module
                                ))
                            }
                        }
                    }
                    .refreshable {
                        await load()
                    }
                }
            }
        case .failed(let error):
            let failure = ChatArtifactFailurePresentation(error: error, scope: scope)
            VStack(spacing: 10) {
                Image(systemName: failure.systemImage)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(failure.title)
                    .font(.headline)
                Text(failure.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if failure.allowsRetry {
                    Button {
                        Task { await load() }
                    } label: {
                        Label(
                            String(localized: "chat.artifact.retry", defaultValue: "Retry", bundle: .module),
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }

    private var breadcrumb: some View {
        Text(parentPath)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityLabel(Text(verbatim: path))
    }

    private func rowLabel(_ entry: ChatArtifactDirectoryEntry) -> some View {
        HStack(spacing: 10) {
            ChatArtifactFolderThumbnail(path: childPath(named: entry.name), entry: entry)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !entry.isDirectory {
                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
        }
    }

    private func load() async {
        let (attempt, previousState) = await MainActor.run {
            let previousState = state
            let attempt = UUID()
            loadAttempt = attempt
            state = .loading
            return (attempt, previousState)
        }
        do {
            let listing = try await loader.list(path: path)
            guard !Task.isCancelled else {
                await restoreStateAfterCancellation(
                    previousState,
                    attempt: attempt
                )
                return
            }
            await MainActor.run {
                guard loadAttempt == attempt else { return }
                state = .listing(listing)
            }
        } catch is CancellationError {
            await restoreStateAfterCancellation(previousState, attempt: attempt)
        } catch {
            let failure = (error as? ChatArtifactError) ?? .loadFailed
            await MainActor.run {
                guard loadAttempt == attempt else { return }
                state = .failed(failure)
            }
        }
    }

    private func restoreStateAfterCancellation(
        _ previousState: LoadState,
        attempt: UUID
    ) async {
        await MainActor.run {
            guard loadAttempt == attempt else { return }
            switch previousState {
            case .loading:
                // An initial load that is cancelled while the view remains
                // mounted needs a recoverable state instead of a permanent
                // spinner. The retry button in the failure view starts a new
                // attempt.
                state = .failed(.loadFailed)
            case .listing, .failed:
                // Refresh cancellation must leave the last usable snapshot
                // visible so the user can pull to refresh again.
                state = previousState
            }
        }
    }

    private func childPath(named name: String) -> String {
        (path as NSString).appendingPathComponent(name)
    }

    private func childRoute(for entry: ChatArtifactDirectoryEntry) -> ChatArtifactFolderRoute {
        ChatArtifactFolderRoute(
            parentPath: path,
            childName: entry.name,
            scope: scope,
            loader: loader
        )
    }

    private var parentPath: String {
        guard path != "/" else { return "/" }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    private enum LoadState: Equatable {
        case loading
        case listing(ChatArtifactDirectoryListing)
        case failed(ChatArtifactError)
    }
}

private struct ChatArtifactFolderThumbnail: View {
    private struct LoadIdentity: Hashable {
        let path: String
        let sourceIdentity: String?
    }

    let path: String
    let entry: ChatArtifactDirectoryEntry

    @Environment(\.chatArtifactLoader) private var loader
    @State private var thumbnailData: Data?
    @State private var thumbnailLoadIdentity: LoadIdentity?

    var body: some View {
        Group {
            if let thumbnailData {
                artifactImage(data: thumbnailData)
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: 34, height: 34)
        .background(.quaternary, in: .rect(cornerRadius: 6))
        .clipShape(.rect(cornerRadius: 6))
        .task(id: LoadIdentity(path: path, sourceIdentity: loader.sourceIdentity)) {
            guard !Task.isCancelled else { return }
            let loadIdentity = LoadIdentity(path: path, sourceIdentity: loader.sourceIdentity)
            thumbnailLoadIdentity = loadIdentity
            thumbnailData = nil
            guard entry.kind == .image, loader.supportsArtifacts else { return }
            do {
                let data = try await loader.thumbnail(path: path, maxDimension: 96).data
                guard !Task.isCancelled, thumbnailLoadIdentity == loadIdentity else { return }
                thumbnailData = data
            } catch {
                guard !Task.isCancelled, thumbnailLoadIdentity == loadIdentity else { return }
                thumbnailData = nil
            }
        }
    }

    @ViewBuilder
    private func artifactImage(data: Data) -> some View {
        #if canImport(UIKit)
        if let image = UIImage(data: data) {
            Image(uiImage: image).resizable()
        } else {
            placeholder
        }
        #elseif canImport(AppKit)
        if let image = NSImage(data: data) {
            Image(nsImage: image).resizable()
        } else {
            placeholder
        }
        #else
        placeholder
        #endif
    }

    private var placeholder: some View {
        let kind: ChatArtifactKind = entry.isDirectory ? .directory : entry.kind
        let glyph = ChatArtifactGalleryClassifier().glyphPresentation(
            for: kind,
            path: path
        )
        return Image(systemName: glyph.systemImageName)
            .font(.body)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(glyph.tint.swiftUIColor)
    }
}

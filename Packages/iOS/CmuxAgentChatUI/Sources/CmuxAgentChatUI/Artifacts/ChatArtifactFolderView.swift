import CmuxAgentChat
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ChatArtifactFolderView: View {
    let path: String
    let scope: ChatArtifactViewerScope
    let onDone: () -> Void

    @Environment(\.chatArtifactLoader) private var loader
    @State private var state: LoadState = .loading

    var body: some View {
        content
            .task(id: path) {
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
                    Text(String(localized: "chat.artifact.folder.empty", defaultValue: "No items", bundle: .module))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
                        }
                    }
                }
            }
        case .failed:
            VStack(spacing: 10) {
                Text(String(localized: "chat.artifact.folder.load_failed", defaultValue: "Couldn't load this folder", bundle: .module))
                    .font(.headline)
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
        await MainActor.run { state = .loading }
        do {
            let listing = try await loader.list(path: path)
            guard !Task.isCancelled else { return }
            await MainActor.run { state = .listing(listing) }
        } catch {
            await MainActor.run { state = .failed }
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
        case failed
    }
}

private struct ChatArtifactFolderThumbnail: View {
    let path: String
    let entry: ChatArtifactDirectoryEntry

    @Environment(\.chatArtifactLoader) private var loader
    @State private var thumbnailData: Data?

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
        .task(id: path) {
            guard entry.kind == .image, loader.supportsArtifacts else { return }
            thumbnailData = try? await loader.thumbnail(path: path, maxDimension: 96).data
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

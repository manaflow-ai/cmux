import CmuxAgentChat
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ChatArtifactFolderView: View {
    let path: String

    @Environment(\.chatArtifactLoader) private var loader
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState = .loading
    @State private var selectedFile: ChatArtifactPathSelection?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(displayName)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "chat.artifact.done", defaultValue: "Done", bundle: .module)) {
                            dismiss()
                        }
                    }
                }
        }
        .task(id: path) {
            await load()
        }
        .sheet(item: $selectedFile) { selection in
            ChatArtifactViewerSheet(path: selection.path)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .entries(let entries):
            if entries.isEmpty {
                Text(String(localized: "chat.artifact.folder.empty", defaultValue: "No files", bundle: .module))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    row(entry)
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

    private func row(_ entry: ChatArtifactDirectoryEntry) -> some View {
        Button {
            guard !entry.isDirectory else { return }
            selectedFile = ChatArtifactPathSelection(path: childPath(named: entry.name))
        } label: {
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
                if entry.isDirectory {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(entry.isDirectory)
    }

    private func load() async {
        await MainActor.run { state = .loading }
        do {
            let listing = try await loader.list(path: path)
            guard !Task.isCancelled else { return }
            await MainActor.run { state = .entries(listing.entries) }
        } catch {
            await MainActor.run { state = .failed }
        }
    }

    private func childPath(named name: String) -> String {
        (path as NSString).appendingPathComponent(name)
    }

    private var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private enum LoadState: Equatable {
        case loading
        case entries([ChatArtifactDirectoryEntry])
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
                Image(systemName: entry.isDirectory ? "folder" : iconName)
                    .font(.body)
                    .foregroundStyle(.secondary)
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
            Image(systemName: iconName)
        }
        #elseif canImport(AppKit)
        if let image = NSImage(data: data) {
            Image(nsImage: image).resizable()
        } else {
            Image(systemName: iconName)
        }
        #else
        Image(systemName: iconName)
        #endif
    }

    private var iconName: String {
        switch entry.kind {
        case .image:
            return "photo"
        case .text:
            return "doc.text"
        case .binary:
            return "doc"
        case .directory:
            return "folder"
        }
    }
}

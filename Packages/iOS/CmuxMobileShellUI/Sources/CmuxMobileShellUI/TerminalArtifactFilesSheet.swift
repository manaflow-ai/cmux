#if os(iOS)
import CmuxAgentChat
import CmuxAgentChatUI
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI
import UIKit

struct TerminalArtifactContext: Identifiable, Equatable {
    let workspaceID: String
    let surfaceID: String

    var id: String { "\(workspaceID)#\(surfaceID)" }
}

struct TerminalArtifactSelection: Identifiable, Equatable {
    let workspaceID: String
    let surfaceID: String
    let path: String

    var id: String { "\(workspaceID)#\(surfaceID)#\(path)" }
}

struct TerminalArtifactFilesSheet: View {
    let workspaceID: String
    let surfaceID: String
    let source: MobileChatEventSource?
    let loader: ChatArtifactLoader

    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState = .loading
    @State private var selection: TerminalArtifactPathSelection?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(L10n.string("mobile.terminal.artifacts.files.title", defaultValue: "Files"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.string("mobile.common.done", defaultValue: "Done")) {
                            dismiss()
                        }
                    }
                }
        }
        .environment(\.chatArtifactLoader, loader)
        .task(id: "\(workspaceID)#\(surfaceID)") {
            await load()
        }
        .sheet(item: $selection) { selection in
            ChatArtifactViewerSheet(path: selection.path)
                .environment(\.chatArtifactLoader, loader)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let artifacts):
            if artifacts.isEmpty {
                ContentUnavailableView(
                    L10n.string("mobile.terminal.artifacts.empty.title", defaultValue: "No files detected on screen"),
                    systemImage: "doc.text.magnifyingglass"
                )
            } else {
                List(artifacts) { artifact in
                    TerminalArtifactFileRow(artifact: artifact) {
                        selection = TerminalArtifactPathSelection(path: artifact.path)
                    }
                }
            }
        case .failed:
            ContentUnavailableView {
                Label(
                    L10n.string("mobile.terminal.artifacts.unreachable.title", defaultValue: "Mac unreachable"),
                    systemImage: "wifi.exclamationmark"
                )
            } description: {
                Text(L10n.string(
                    "mobile.terminal.artifacts.unreachable.message",
                    defaultValue: "Check the connection to your Mac and try again."
                ))
            } actions: {
                Button {
                    Task { await load() }
                } label: {
                    Label(L10n.string("mobile.terminal.artifacts.retry", defaultValue: "Retry"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func load() async {
        await MainActor.run { state = .loading }
        guard let source else {
            await MainActor.run { state = .failed }
            return
        }
        do {
            let response = try await source.terminalArtifactScan(workspaceID: workspaceID, surfaceID: surfaceID)
            await MainActor.run { state = .loaded(response.artifacts) }
        } catch {
            await MainActor.run { state = .failed }
        }
    }

    private enum LoadState: Equatable {
        case loading
        case loaded([TerminalArtifactReference])
        case failed
    }
}

private struct TerminalArtifactPathSelection: Identifiable {
    let path: String
    var id: String { path }
}

private struct TerminalArtifactFileRow: View {
    let artifact: TerminalArtifactReference
    let open: () -> Void

    @Environment(\.chatArtifactLoader) private var loader
    @State private var thumbnail: ChatArtifactThumbnail?

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                leading
                VStack(alignment: .leading, spacing: 3) {
                    Text(artifact.displayName)
                        .lineLimit(1)
                    Text(artifact.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: artifact.path) {
            guard artifact.kind == .image else { return }
            thumbnail = try? await loader.thumbnail(path: artifact.path, maxDimension: 96)
        }
    }

    @ViewBuilder
    private var leading: some View {
        if let thumbnail,
           let image = UIImage(data: thumbnail.data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: symbolName)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
        }
    }

    private var symbolName: String {
        switch artifact.kind {
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
#endif

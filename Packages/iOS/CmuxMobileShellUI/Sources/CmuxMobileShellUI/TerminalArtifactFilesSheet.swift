#if os(iOS)
import CmuxAgentChat
import CmuxAgentChatUI
import CmuxMobileShell
import SwiftUI

struct TerminalArtifactContext: Identifiable {
    let workspaceID: String
    let surfaceID: String
    let anchor: UnitPoint

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

    @State private var state: LoadState = .loading
    @State private var viewMode: ViewMode = .list
    @State private var selection: TerminalArtifactPathSelection?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(String(
                    localized: "terminal.artifact.gallery.title",
                    defaultValue: "Files",
                    bundle: .module
                ))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(
                            localized: "terminal.artifact.gallery.done",
                            defaultValue: "Done",
                            bundle: .module
                        )) {
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        viewModePicker
                    }
                }
        }
        .frame(idealWidth: 380, idealHeight: 520)
        .task(id: "\(workspaceID)#\(surfaceID)") {
            await load()
        }
        .sheet(item: $selection) { selection in
            ChatArtifactViewerSheet(path: selection.path, scope: .terminal)
                .environment(\.chatArtifactLoader, loader)
        }
    }

    private var viewModePicker: some View {
        Picker(
            String(
                localized: "terminal.artifact.gallery.view_mode",
                defaultValue: "View",
                bundle: .module
            ),
            selection: $viewMode
        ) {
            Label(
                String(
                    localized: "terminal.artifact.gallery.view_mode.list",
                    defaultValue: "List",
                    bundle: .module
                ),
                systemImage: "list.bullet"
            )
            .labelStyle(.iconOnly)
            .tag(ViewMode.list)

            Label(
                String(
                    localized: "terminal.artifact.gallery.view_mode.grid",
                    defaultValue: "Icons",
                    bundle: .module
                ),
                systemImage: "square.grid.2x2"
            )
            .labelStyle(.iconOnly)
            .tag(ViewMode.grid)
        }
        .pickerStyle(.segmented)
        .frame(width: 112)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView(String(
                localized: "terminal.artifact.gallery.loading",
                defaultValue: "Loading files…",
                bundle: .module
            ))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let artifacts):
            if artifacts.isEmpty {
                ContentUnavailableView(
                    String(
                        localized: "terminal.artifact.gallery.empty",
                        defaultValue: "No files in view",
                        bundle: .module
                    ),
                    systemImage: "tray"
                )
            } else {
                loadedContent(artifacts)
            }
        case .failed:
            ContentUnavailableView {
                Label(
                    String(
                        localized: "terminal.artifact.gallery.unreachable.title",
                        defaultValue: "Mac unreachable",
                        bundle: .module
                    ),
                    systemImage: "wifi.exclamationmark"
                )
            } description: {
                Text(String(
                    localized: "terminal.artifact.gallery.unreachable.message",
                    defaultValue: "Check the connection to your Mac and try again.",
                    bundle: .module
                ))
            } actions: {
                Button {
                    Task { await load() }
                } label: {
                    Label(
                        String(
                            localized: "terminal.artifact.gallery.retry",
                            defaultValue: "Retry",
                            bundle: .module
                        ),
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private func loadedContent(_ artifacts: [TerminalArtifactReference]) -> some View {
        switch viewMode {
        case .list:
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(artifacts) { artifact in
                        TerminalArtifactGalleryItemView(
                            artifact: artifact,
                            layout: .list,
                            loader: loader,
                            open: { open(artifact) }
                        )
                        Divider()
                            .padding(.leading, 72)
                    }
                }
            }
        case .grid:
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 16) {
                    ForEach(artifacts) { artifact in
                        TerminalArtifactGalleryItemView(
                            artifact: artifact,
                            layout: .grid,
                            loader: loader,
                            open: { open(artifact) }
                        )
                    }
                }
                .padding(16)
            }
        }
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 96), spacing: 12)]
    }

    private func open(_ artifact: TerminalArtifactReference) {
        selection = TerminalArtifactPathSelection(path: artifact.path)
    }

    private func load() async {
        await MainActor.run { state = .loading }
        guard let source else {
            await MainActor.run { state = .failed }
            return
        }
        do {
            let response = try await source.terminalArtifactScan(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                visibleOnly: true
            )
            guard !Task.isCancelled else { return }
            // Gallery v1 intentionally excludes folders. Folder navigation and a
            // smarter high-count strategy are deferred to a later iteration.
            let files = response.artifacts.filter { $0.kind != .directory }
            await MainActor.run { state = .loaded(files) }
        } catch is CancellationError {
            return
        } catch {
            await MainActor.run { state = .failed }
        }
    }

    private enum LoadState: Equatable {
        case loading
        case loaded([TerminalArtifactReference])
        case failed
    }

    private enum ViewMode: Hashable {
        case list
        case grid
    }

    private struct TerminalArtifactPathSelection: Identifiable {
        let path: String
        var id: String { path }
    }
}
#endif

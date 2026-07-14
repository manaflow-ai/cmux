public import CmuxHive
public import SwiftUI

/// The remote-Mac viewer window's root: the remote workspace list on the
/// left, the selected terminal's live view on the right, with connection
/// state overlays.
public struct HiveViewerRootView: View {
    @Bindable private var session: HiveRemoteMacSession
    @State private var selection: HiveViewerSelection?
    /// Terminal sessions per (workspace, terminal), kept while the window is
    /// open so switching back to a terminal reuses its streamed grid.
    @State private var terminalSessions: [HiveViewerSelection: HiveRemoteTerminalSession] = [:]

    /// Creates the viewer root over one Mac session.
    public init(session: HiveRemoteMacSession) {
        self.session = session
    }

    public var body: some View {
        NavigationSplitView {
            HiveViewerWorkspaceList(
                workspaces: session.workspaces,
                selection: $selection
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 230)
        } detail: {
            detail
        }
        .navigationTitle(session.displayName)
        .onAppear { session.connect() }
        .onChange(of: session.workspaces) { _, workspaces in
            reconcileSelection(workspaces: workspaces)
        }
        .task {
            // The first list arrival picks the host's selected workspace.
            reconcileSelection(workspaces: session.workspaces)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch session.phase {
        case .idle, .connecting:
            ProgressView(String(localized: "hive.viewer.connecting", defaultValue: "Connecting…"))
        case .failed(let message):
            ContentUnavailableView {
                Label(
                    String(localized: "hive.viewer.failed.title", defaultValue: "Couldn't Connect"),
                    systemImage: "wifi.exclamationmark"
                )
            } description: {
                Text(message)
            } actions: {
                Button(String(localized: "hive.viewer.retry", defaultValue: "Retry")) {
                    session.connect()
                }
            }
        case .connected, .reconnecting:
            if let selection, let terminal = terminalSession(for: selection) {
                HiveRemoteTerminalPane(terminal: terminal)
                    .id(selection)
            } else {
                ContentUnavailableView {
                    Label(
                        String(localized: "hive.viewer.noTerminal.title", defaultValue: "No Terminal"),
                        systemImage: "terminal"
                    )
                } description: {
                    Text(String(
                        localized: "hive.viewer.noTerminal.description",
                        defaultValue: "Select a terminal in the sidebar to view it live."
                    ))
                }
            }
        }
    }

    private func terminalSession(for selection: HiveViewerSelection) -> HiveRemoteTerminalSession? {
        if let existing = terminalSessions[selection] { return existing }
        guard let client = session.client else { return nil }
        let terminal = HiveRemoteTerminalSession(
            client: client,
            workspaceID: selection.workspaceID,
            terminalID: selection.terminalID,
            retryDelay: HiveReconnectBackoff().delay(attempt:)
        )
        terminalSessions[selection] = terminal
        return terminal
    }

    private func reconcileSelection(workspaces: [HiveRemoteWorkspace]) {
        if let selection,
           workspaces.contains(where: { workspace in
               workspace.id == selection.workspaceID
                   && workspace.terminals.contains { $0.id == selection.terminalID }
           }) {
            return
        }
        let preferred = workspaces.first(where: \.isSelected) ?? workspaces.first
        guard let workspace = preferred, let terminal = workspace.defaultTerminal else {
            selection = nil
            return
        }
        selection = HiveViewerSelection(workspaceID: workspace.id, terminalID: terminal.id)
    }
}

/// One selectable terminal in the viewer sidebar.
public struct HiveViewerSelection: Hashable, Sendable {
    /// The host workspace id.
    public let workspaceID: String
    /// The host surface id.
    public let terminalID: String

    public init(workspaceID: String, terminalID: String) {
        self.workspaceID = workspaceID
        self.terminalID = terminalID
    }
}


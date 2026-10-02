import Foundation

extension Notification.Name {
    static let workspaceShellActivityDidChange = Notification.Name(
        "cmux.workspaceShellActivityDidChange"
    )
}

/// The selected terminal identity used by Files while it probes plain SSH.
struct FileExplorerSelectedTerminalContext: Equatable, Sendable {
    let workspaceId: UUID
    let panelId: UUID
    let ttyName: String
    let remoteWorkingDirectory: String?
}

@MainActor
extension Workspace {
    func postFileExplorerShellActivityChangeIfFocused(panelId: UUID) {
        guard panelId == focusedPanelId else { return }
        NotificationCenter.default.post(
            name: .workspaceShellActivityDidChange,
            object: self,
            userInfo: ["workspaceId": id, "panelId": panelId]
        )
    }

    /// Returns the selected local terminal's current TTY and remote title cwd.
    /// Managed remote workspaces are deliberately excluded because their
    /// configured transport remains authoritative.
    var fileExplorerSelectedTerminalContext: FileExplorerSelectedTerminalContext? {
        guard !usesRemoteDirectoryProvenance,
              let panelId = focusedPanelId,
              let terminalPanel = terminalPanel(for: panelId),
              hasCurrentRuntimeReportedTTY(panelId: panelId, terminal: terminalPanel),
              let ttyName = surfaceTTYNames[panelId]
                .map({ TerminalSSHSessionDetector.normalizeTTYName($0) }),
              !ttyName.isEmpty else { return nil }
        return FileExplorerSelectedTerminalContext(
            workspaceId: id,
            panelId: panelId,
            ttyName: ttyName,
            remoteWorkingDirectory: panelTitles[panelId]
                .flatMap(TerminalSSHSessionDetector.remoteWorkingDirectory(fromTitle:))
        )
    }
}

import CMUXMobileCore

struct WorkspaceTitleMenuValue: Equatable {
    let isEnabled: Bool
    let workspaceName: String
    let hasUnread: Bool
    let canCustomizeWorkspace: Bool
    let canRenameWorkspace: Bool
    let canToggleReadState: Bool
    let canCloseWorkspace: Bool
    /// Whether the menu offers Reconnect — the disconnected state's manual
    /// recovery entry now that no pill covers the terminal. Reauthentication
    /// keeps its own blocking banner instead.
    let canReconnect: Bool
    let labelToken: WorkspaceTitleMenuLabelToken
    let terminalTheme: TerminalTheme
}

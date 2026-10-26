/// Every protocol-12 command `CmuxTUIControl` sends, by wire name.
///
/// This list is the iOS client's census: `cmux-tui/scripts/assign-ipc-method-ids.py` reads these
/// cases and sets `clients: ios` on exactly these commands in `cmux-tui/spec/sdk-schema.json`, and
/// `scripts/cmux-next/gen-phone-lane-fields.py` refuses a `clients: ios` command that the Mac's
/// phone lane (`DaemonLanePolicy.allowedCommands`) would refuse. Add a case here before sending a
/// new command, then run both scripts.
enum CmuxTUICommand: String, Sendable, CaseIterable {
    // Session.
    case identify
    case setClientInfo = "set-client-info"
    case subscribe
    // Workspaces and layout.
    case listWorkspaces = "list-workspaces"
    case createWorkspace = "create-workspace"
    case renameWorkspace = "rename-workspace"
    case closeWorkspace = "close-workspace"
    case createTerminal = "create-terminal"
    case newScreen = "new-screen"
    case newTab = "new-tab"
    case split
    case processInfo = "process-info"
    // Terminal streams, input and geometry.
    case attachSurface = "attach-surface"
    case detachAttachedView = "detach-attached-view"
    case send
    case setClientSizing = "set-client-sizing"
    case resizeSurface = "resize-surface"
    case resizeAttachedView = "resize-attached-view"
    case releaseAttachedViewSize = "release-attached-view-size"
    case getCellPixels = "get-cell-pixels"
    case setTerminalIdlePolicy = "set-terminal-idle-policy"
    // Browser surfaces.
    case browserFramePresented = "browser-frame-presented"
    case browserMouseGuarded = "browser-mouse-guarded"
    case browserWheelGuarded = "browser-wheel-guarded"
    case browserInsertText = "browser-insert-text"
    case browserKeyPress = "browser-key-press"
    case browserNavigate = "browser-navigate"
    case browserBack = "browser-back"
    case browserForward = "browser-forward"
    case browserReload = "browser-reload"
}

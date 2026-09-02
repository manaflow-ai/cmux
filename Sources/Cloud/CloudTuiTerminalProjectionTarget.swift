/// A concrete remote pane location accepted by cmux-tui's `terminal.project` command.
///
/// The public terminal resource can outlive every tab that displays it. When that happens,
/// the native macOS mirror first creates one remote view in an existing pane, then resolves
/// the daemon-local surface id for the byte attachment.
struct CloudTuiTerminalProjectionTarget: Equatable, Sendable {
    let workspaceID: String
    let screenID: String
    let paneID: String
    let index: Int
}

/// A concrete remote pane location accepted by cmux-tui's `terminal.project` command.
///
/// The public terminal resource can outlive every tab that displays it. When that happens,
/// the native macOS mirror first creates one remote view in an existing pane, then resolves
/// the daemon-local surface id for the byte attachment.
public struct CloudTuiTerminalProjectionTarget: Equatable, Sendable {
    public let workspaceID: String
    public let screenID: String
    public let paneID: String
    public let index: Int

    public init(workspaceID: String, screenID: String, paneID: String, index: Int) {
        self.workspaceID = workspaceID
        self.screenID = screenID
        self.paneID = paneID
        self.index = index
    }
}

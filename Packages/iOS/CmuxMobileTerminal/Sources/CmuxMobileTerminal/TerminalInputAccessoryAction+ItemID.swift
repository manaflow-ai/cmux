import CmuxMobileTerminalKit

public extension TerminalInputAccessoryAction {
    /// This built-in action's unified identifier in the configurable region,
    /// pairing it with custom actions under one ``ToolbarItemID`` space.
    var itemID: ToolbarItemID { .builtin(rawValue) }
}

/// Where a Cloud chat's Terminal and Browser open (the header's buttons, the chat menu's New Terminal and New Browser,
/// cmux#55413): on the chat's Cloud machine, never on this Mac. Austin, 2026-11-24: "if i click the browser from the
/// cloud chat it should open a cloudbrowser which is the browser that it is essentially on the cloud machine".
///
/// The Browser is the machine's own desktop (the `cmux-rd` remote view Open Desktop shows): the browser the agent
/// drives there, with the machine's localhost and its sessions. A workspace never mixes machines and a remote tree's
/// remote view record never opens, so the desktop is a tab of this Mac's tree: beside the chat when a Mac tab shows the
/// chat in place, else in its own Desktop workspace. The Terminal of a chat whose workspace is the machine's is the chat
/// pane's own split, which already runs there; a Mac tab showing the chat in place cannot hold one, so it opens on the
/// machine as `cloud ssh` does, in the chat's folder.
public nonisolated enum CloudChatToolRoute: Equatable, Sendable {
    /// As for a chat on this Mac: the chat pane's own split (a Cloud chat's workspace on its machine runs it there).
    case asLocal
    /// The machine's desktop, a tab beside the Mac tab that shows the chat.
    case desktopBeside
    /// The machine's desktop in its own Desktop workspace on this Mac.
    case desktopWorkspace
    /// A terminal tab on the machine, in the chat's folder.
    case machineTerminal

    public enum Tool: Sendable { case terminal, browser, other }

    /// `onCloud`: the chat's tab is a Cloud machine's. `shownOnThisMac`: a Mac tab shows it in place.
    public static func resolve(_ tool: Tool, onCloud: Bool, shownOnThisMac: Bool) -> Self {
        guard onCloud else { return .asLocal }
        switch tool {
        case .browser: return shownOnThisMac ? .desktopBeside : .desktopWorkspace
        case .terminal: return shownOnThisMac ? .machineTerminal : .asLocal
        case .other: return .asLocal
        }
    }
}

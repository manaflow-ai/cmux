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

/// Which Cloud chat a person's new terminal or browser belongs to when it names no other place (cmux#57249): the pane
/// toolbar's Terminal and Browser, their keys, the palette and menu bar, Split Right / Split Down (Cmd-D, Cmd-Shift-D),
/// Split Browser and the New Tab page's picks. User, 2026-11-25: "if we click these buttons or are focused on a cloud
/// chat it should go into the cloud terminal and cloud browser". Every such path asks this one rule, then opens through
/// ``CloudChatToolRoute`` as the chat header's tools do, so none of them opens on this Mac again.
public nonisolated enum CloudChatFocus: Equatable, Sendable {
    /// Open as before: no Cloud chat is focused, or the open names its own place.
    case asBefore
    /// Open on the Cloud machine of chat tab `key` of machine `machine`.
    case cloudChat(machine: String, key: String)

    /// A tab a pane shows, as this rule needs it.
    public struct Shown: Equatable, Sendable {
        /// The tab's machine and id.
        public var machine: String, key: String
        /// The Cloud chat a Mac tab shows in place (``CloudFrontedChats``), as (machine, tab id).
        public var fronts: (machine: String, key: String)?
        /// The tab's machine is a Cloud machine.
        public var onCloud: Bool
        /// The tab is an agent chat.
        public var isChat: Bool

        public init(machine: String, key: String, fronts: (machine: String, key: String)? = nil, onCloud: Bool, isChat: Bool) {
            (self.machine, self.key, self.fronts, self.onCloud, self.isChat) = (machine, key, fronts, onCloud, isChat)
        }

        public static func == (a: Self, b: Self) -> Bool {
            a.machine == b.machine && a.key == b.key && a.fronts?.machine == b.fronts?.machine && a.fronts?.key == b.fronts?.key
                && a.onCloud == b.onCloud && a.isChat == b.isChat
        }
    }

    /// `byPerson`: a person's own open (a click, key, menu or palette), not a script's. `namesPlace`: the open names its
    /// own place (beside an agent's caller, a divider's Insert New, an explicit tab of another pane). `shown`: the tab the
    /// pane shows.
    public static func resolve(byPerson: Bool, namesPlace: Bool, shown: Shown?) -> Self {
        guard byPerson, !namesPlace, let shown else { return .asBefore }
        if let front = shown.fronts { return .cloudChat(machine: front.machine, key: front.key) }
        return shown.onCloud && shown.isChat ? .cloudChat(machine: shown.machine, key: shown.key) : .asBefore
    }

    /// What a New Tab page opened from a Cloud chat opens on the chat's machine.
    public enum Pick: Equatable, Sendable {
        /// A terminal that types `typing` once made (nil: none).
        case terminal(typing: String?)
        /// The machine's desktop.
        case browser
    }

    /// A New Tab page pick from a Cloud chat, nil to pick as before. A Terminal pick runs its one line (`run`) or types
    /// it; a Browser pick with no address opens the desktop (it takes none, so an address opens here). Only what was typed
    /// in the page's field (`picked`) and replaces the page (not `keep`): its setup actions (a harness's Sign In, Install,
    /// Log In, which act on this Mac's harness) and an agent pick are this Mac's.
    public static func pick(terminal: Bool, browser: Bool, text: String, run: Bool, keep: Bool, picked: Bool = true) -> Pick? {
        guard picked, !keep else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if terminal {
            guard run else { return .terminal(typing: text.isEmpty ? nil : text) }
            return trimmed.contains(where: \.isNewline) ? nil : .terminal(typing: trimmed.isEmpty ? nil : trimmed + "\n")
        }
        return browser && trimmed.isEmpty ? .browser : nil
    }
}

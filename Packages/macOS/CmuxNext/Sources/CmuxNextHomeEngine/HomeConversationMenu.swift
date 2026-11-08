public import AppKit
public import CmuxHomeCore
public import CmuxNextActions
import CmuxNextHome
import CmuxNextHomeModel

/// One item of a Home menu: a catalog action with the registry's own title and the arguments it
/// runs with. The native list's row menu and the React Messages page (`cmux.home.messages.menu`)
/// draw the same entries, so both run the palette's and the CLI's one path.
public struct HomeMenuEntry: Hashable, Sendable {
    public var action: ActionID
    public var title: String
    public var arguments: [String: ActionValue]
    /// A separator goes before it (Show Hidden Conversations, the teams).
    public var separatorBefore: Bool
    /// A choice's state (the active team), nil for a plain action.
    public var checked: Bool?

    public init(action: ActionID, title: String, arguments: [String: ActionValue] = [:], separatorBefore: Bool = false,
                checked: Bool? = nil) {
        (self.action, self.title, self.arguments, self.separatorBefore, self.checked) = (action, title, arguments, separatorBefore, checked)
    }

    /// Its text arguments (every Home menu argument is an id), as a page carries them.
    public var textArguments: [String: String] {
        arguments.compactMapValues { if case .string(let text) = $0 { text } else { nil } }
    }

    /// An entry to run from a page's choice: `action` with its text arguments.
    public init(action: String, textArguments: [String: String]) {
        self.init(action: ActionID(rawValue: action), title: "", arguments: textArguments.mapValues(ActionValue.string))
    }

    /// Runs it as the person's choice. Delete Conversation (`home.hideConversation`) asks first, as
    /// Messages does (`HomeListActions.confirmDelete`), in `window`.
    @MainActor
    public func perform(in registry: ActionRegistry, window: NSWindow?) {
        let run: @MainActor @Sendable () -> Void = { [action, arguments] in
            _ = registry.perform(action, invocation: ActionInvocation(arguments: arguments, origin: .user))
        }
        if action == "home.hideConversation" { HomeListActions.confirmDelete(in: window, run) } else { run() }
    }
}

/// A Home conversation's menu (its row in the list): Conversation Info (a Cloud Chief shared with
/// teammates), Usage…, Import Memories…, Archive Chief and Delete Chief… on a Chief's row; Group Info,
/// Hide or Show Alerts, Rename, Add People and Leave on a DM or group's row (the same actions as the
/// palette and the CLI); then Chat Colors… on every chat.
@MainActor
public struct HomeConversationMenu {
    public var registry: ActionRegistry
    public var directory: HomeDirectory
    public var groupActions: HomeGroupActions
    /// The Chief Delete Chief… removes for a row, or nil (the default Chief has none).
    public var deletableChief: (InboxRow) -> String?
    /// Chief Usage's action and menu title, nil in a build without this Mac's Chiefs.
    public var usage: (action: ActionID, title: String)?
    /// Import Memories… (`chief.importMemories`).
    public var importMemories: ActionID

    public init(registry: ActionRegistry, directory: HomeDirectory, groupActions: HomeGroupActions,
                deletableChief: @escaping (InboxRow) -> String?, usage: (action: ActionID, title: String)?, importMemories: ActionID) {
        self.registry = registry
        self.directory = directory
        self.groupActions = groupActions
        self.deletableChief = deletableChief
        self.usage = usage
        self.importMemories = importMemories
    }

    /// The actions a row's menu or the compose menu may run (what `cmux.home.messages.perform` takes).
    public var offered: Set<ActionID> {
        var actions: Set<ActionID> = [
            "home.conversationInfo", "home.muteConversation", "home.unmuteConversation", "home.renameConversation",
            "home.addMembers", "home.leaveConversation", "home.chatColors", "home.archiveChief", "home.deleteChief",
            "home.hideConversation", importMemories,
        ]
        actions.formUnion(HomePageMenus.composeActions)
        if let usage { actions.insert(usage.action) }
        return actions
    }

    public func entries(for row: InboxRow) -> [HomeMenuEntry] {
        let id = row.id
        func item(_ action: ActionID, _ title: String? = nil, _ arguments: [String: ActionValue] = [:]) -> [HomeMenuEntry] {
            guard let title = title ?? registry.title(for: action) else { return [] }
            return [HomeMenuEntry(action: action, title: title, arguments: arguments)]
        }
        let conversation: [String: ActionValue] = ["conversation": .string(id.rawValue)]
        var items: [HomeMenuEntry] = []
        if row.kind == .chief {
            let usage = usage.map { item($0.action, $0.title) } ?? []
            // Delete for any Chief but the default one; Archive for a cloud Chief (this Mac's have no archive).
            let delete = deletableChief(row).map { item("home.deleteChief", nil, ["chief": .string($0)]) } ?? []
            // Import Memories…: into this Mac's Chief, or into the Cloud Chief the row is.
            let cloudChief = row.summary.participants.lazy.compactMap({ directory.chief(for: $0.id) }).first
            let bring = item(importMemories, nil, cloudChief.map { ["chief": .string($0.id)] } ?? [:])
            if let chief = cloudChief {
                // A Cloud Chief's conversation is shared with teammates from its info (Add People…).
                items = item("home.conversationInfo", nil, conversation) + usage + bring
                    + item("home.archiveChief", nil, ["chief": .string(chief.id)]) + delete
            } else {
                items = usage + bring + delete
            }
        } else {
            if row.kind == .group { items += item("home.conversationInfo", HomeGroupInfo.groupInfoMenuTitle, conversation) }
            if let info = groupActions.info(id), info.canMute {
                items += item(info.muted ? "home.unmuteConversation" : "home.muteConversation", nil, conversation)
            }
            if row.kind == .group {
                // Someone else's Chief conversation shared with me: its owner names it and adds people.
                if row.summary.declaredKind != .chief {
                    items += item("home.renameConversation", nil, conversation)
                    items += item("home.addMembers", nil, conversation)
                }
                items += item("home.leaveConversation", nil, conversation)
            }
        }
        // Chat Colors… on every chat (Chiefs, DMs and groups): its own bubble and text colours.
        return items + item("home.chatColors", nil, conversation)
    }
}

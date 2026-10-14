/// The name a workspace the user never named takes from its front tab
/// (hq#1957, `workspaces.autoName`). Pure, so every case is tested; the
/// sidebar row (`AppServices.sidebarPageFace`) and the one-time rename
/// (`WorkspaceAutoNamer`) both read it.
///
/// A workspace is the user's to name while it has a title or a name the
/// daemon did not give (`NewWorkspaceName.isDefaultWorkspaceName`): the rule
/// never names it then.
nonisolated struct WorkspaceAutoName: Equatable {
    /// What the rule reads of the workspace's front tab.
    enum Front: Equatable {
        /// A browser tab: its page title as the sidebar showed it before
        /// (the tab's user name, else its page title, else its host).
        /// `offTheRecord` for an incognito page, whose title never reaches
        /// the daemon (R102).
        case browser(title: String?, offTheRecord: Bool)
        /// An agent chat: the tab's user name, else its chat's title (which
        /// may be only its first prompt); nil for a chat with no title yet
        /// (or a New Tab page). `generatedTitle` is the chat's real title
        /// (the agent's or the one given to the chat), never its first
        /// prompt: the only name `persist` writes.
        case chat(userName: String?, title: String?, generatedTitle: String? = nil)
        /// A terminal, or any other tab: `NewWorkspaceName.forTab`'s input.
        case terminal(NewWorkspaceName.Tab)
    }

    /// `workspaces.autoName`: off turns both variants off.
    var enabled: Bool
    var variant: WorkspaceAutoNameVariant

    /// The name the sidebar row shows for a workspace named `name` (titled
    /// `title`) whose front tab is `front`; nil keeps the workspace's own
    /// name. Both variants show it.
    func label(name: String, title: String?, front: Front?) -> String? {
        guard enabled, !Self.isUserNamed(name: name, title: title), let front else { return nil }
        return Self.derived(front)
    }

    /// The name to write to the daemon once (variant `persist`), or nil to
    /// write nothing. `alreadyRenamed`: this app renamed (or asked to rename)
    /// the workspace before, so it never does again.
    func persistedName(name: String, title: String?, front: Front?, isLocalMachine: Bool, alreadyRenamed: Bool) -> String? {
        guard variant == .persist, !alreadyRenamed else { return nil }
        // An incognito page's title stays in memory: the daemon keeps workspace names in closed history.
        if case .browser(_, offTheRecord: true)? = front { return nil }
        return label(name: name, title: title, front: front)
    }

    /// Whether a rename decided earlier may still go out now that the
    /// workspace is named `currentName` and titled `currentTitle`.
    func confirmsRename(currentName: String, currentTitle: String?) -> Bool {
        true
    }

    /// Whether the user named the workspace: a title, or a name the daemon did not give.
    static func isUserNamed(name: String, title: String?) -> Bool {
        !(title ?? "").isEmpty || !NewWorkspaceName.isDefaultWorkspaceName(name)
    }

    /// The name `front` gives, one line and at most `NewWorkspaceName.maxLength` characters.
    static func derived(_ front: Front) -> String? {
        switch front {
        case let .browser(title, _): NewWorkspaceName.clean(title)
        case let .chat(userName, title, _): NewWorkspaceName.clean(userName) ?? NewWorkspaceName.clean(title)
        case let .terminal(tab): NewWorkspaceName.forTab(tab)
        }
    }
}

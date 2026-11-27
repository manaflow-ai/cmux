public import CmuxNextDaemon

/// The name a workspace the user never named takes from its front tab
/// (hq#1957, `workspaces.autoName`). The rules are Rust's (`cmux-workspace-naming`); the
/// sidebar row (`AppServices.sidebarPageFace`) and persistent naming
/// (`WorkspaceAutoNamer`) both read it.
///
/// A workspace is the user's to name while it has a title or user-owned name.
/// An automatically supplied name remains automatic after its first chat title.
public nonisolated struct WorkspaceAutoName: Equatable, Sendable {
    /// What the rule reads of the workspace's front tab.
    public nonisolated enum Front: Equatable, Sendable, Encodable {
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
    public var enabled: Bool
    public var variant: WorkspaceAutoNameVariant

    public init(enabled: Bool, variant: WorkspaceAutoNameVariant) {
        self.enabled = enabled
        self.variant = variant
    }

    /// The name the sidebar row shows for a workspace named `name` (titled
    /// `title`) whose front tab is `front`; nil keeps the workspace's own
    /// name. Both variants show it.
    ///
    /// `anchor` is the work tab the row was named for before a page opened
    /// beside it (`SidebarMapping.FaceTabs.work`: the last focused chat or
    /// terminal) when it has one. A browser page opened beside it (an agent
    /// showing its PR in a split) never renames the workspace: the anchor
    /// keeps naming it, so the row does not flip to whatever page is focused.
    public func label(name: String, title: String?, front: Front?, anchor: Front? = nil,
                      nameSource: WorkspaceNameSource = .auto, nameRevision: UInt64 = 0,
                      allowsLegacyDefaults: Bool = true) -> String? {
        let named = Named(name: name, title: title, source: nameSource, revision: nameRevision,
                          allowsLegacyDefaults: allowsLegacyDefaults)
        return WorkspaceNamingRules().string("label", LabelRequest(enabled: enabled, named: named, front: front, anchor: anchor),
                                             key: "label")
    }

    /// The name to write to the daemon (variant `persist`), or nil to
    /// write nothing: only a front chat's generated title, and only for a
    /// daemon that supports the name-source protocol. The local daemon is
    /// accepted for compatibility with older callers; remote daemons must set
    /// `supportsNameSource`. `alreadyRenamed` prevents repeat submissions in
    /// one app run.
    public func persistedName(name: String, title: String?, front: Front?, isLocalMachine: Bool,
                              supportsNameSource: Bool = false, alreadyRenamed: Bool,
                              nameSource: WorkspaceNameSource = .auto, nameRevision: UInt64 = 0,
                              allowsLegacyDefaults: Bool = true) -> String? {
        let named = Named(name: name, title: title, source: nameSource, revision: nameRevision,
                          allowsLegacyDefaults: allowsLegacyDefaults)
        let persist = Persist(isLocalMachine: isLocalMachine, supportsNameSource: supportsNameSource, alreadyRenamed: alreadyRenamed)
        return WorkspaceNamingRules().string("persisted_name", PersistRequest(enabled: enabled, variant: variant, named: named,
                                                                              front: front, persist: persist), key: "name")
    }

    /// Whether a rename decided earlier may still go out now that the
    /// workspace is named `currentName` and titled `currentTitle`.
    public func confirmsRename(currentName: String, currentTitle: String?, nameSource: WorkspaceNameSource = .auto,
                               nameRevision: UInt64 = 0, allowsLegacyDefaults: Bool = true) -> Bool {
        !Self.isUserNamed(name: currentName, title: currentTitle, nameSource: nameSource, nameRevision: nameRevision,
                          allowsLegacyDefaults: allowsLegacyDefaults)
    }

    /// Whether a title or name-source authority protects the workspace from automatic naming.
    public static func isUserNamed(name: String, title: String?, nameSource: WorkspaceNameSource = .auto,
                                   nameRevision: UInt64 = 0, allowsLegacyDefaults: Bool = true) -> Bool {
        let named = Named(name: name, title: title, source: nameSource, revision: nameRevision,
                          allowsLegacyDefaults: allowsLegacyDefaults)
        return WorkspaceNamingRules().flag("is_user_named", ["named": named], key: "user_named")
    }

    /// The name `front` gives, one line and at most `NewWorkspaceName.maxLength` characters.
    public static func derived(_ front: Front) -> String? {
        WorkspaceNamingRules().string("derived", ["front": front], key: "name")
    }

    /// A workspace's name state as the rules read it.
    private nonisolated struct Named: Encodable {
        var name: String
        var title: String?
        var source: WorkspaceNameSource
        var revision: UInt64
        var allowsLegacyDefaults: Bool
    }

    private nonisolated struct Persist: Encodable {
        var isLocalMachine: Bool
        var supportsNameSource: Bool
        var alreadyRenamed: Bool
    }

    private nonisolated struct LabelRequest: Encodable {
        var enabled: Bool
        var named: Named
        var front: Front?
        var anchor: Front?
    }

    private nonisolated struct PersistRequest: Encodable {
        var enabled: Bool
        var variant: WorkspaceAutoNameVariant
        var named: Named
        var front: Front?
        var persist: Persist
    }
}

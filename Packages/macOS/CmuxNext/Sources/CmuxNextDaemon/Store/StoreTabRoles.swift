public import Observation

/// The tabs of one store in the two roles that app readers follow across the whole tree: agent chat
/// tabs (``TabModel/agentSession``, by acpmux session) and browser tabs (with their address and
/// favicon). The sidebar's New Tab pages, the Priority view's remote chats and the omnibar's site
/// icons read these sets instead of a walk of every workspace, screen, pane and tab, and observe one
/// revision per role instead of every pane's tab list (CLAUDE.md "Go past Chrome where cmux is
/// scripted": a change costs the records it names, never the session).
///
/// ``StoreIndex`` reports each tab record it keys or drops (with the workspace that holds it), and the record
/// reports a change of the fields a role reads (`kind`, `conversation`, `url`, `faviconURL`). The revisions move
/// once per publish (`DaemonStore.publishTabListChange`, once per apply and per intent shown) and only for a net
/// change: a re-key or a rebuild of the same tree moves neither. A pending create of a chat or browser tab can
/// move one at an apply: the overlay's restore makes a new provisional record for it (`IntentOverlay`), and a
/// record is filed by identity.
@MainActor @Observable public final class StoreTabRoles {
    /// What a chat member contributes: its tab id and acpmux session, nil for a blank chat record. The id too: a
    /// record dropped and another made in one apply may reuse its `ObjectIdentifier`.
    private struct Chat: Equatable { var id: String, session: String? }
    /// What a browser member contributes to a site icon lookup: with the workspace that holds it, so a reader can
    /// leave out an incognito window's tabs without a lookup that observes the tab list.
    private struct Browser: Equatable { var id: String, url: String?, favicon: String?, workspace: String? }

    /// Bumped once per publish that changed which tabs are agent chats or the session of one.
    public private(set) var chatRevision: UInt64 = 0
    /// Bumped once per publish that changed which tabs are browser tabs, or the address or favicon of one.
    public private(set) var browserRevision: UInt64 = 0

    @ObservationIgnored private var records: [ObjectIdentifier: TabModel] = [:]
    /// The workspace each keyed tab record was keyed in (every record, so a terminal that becomes a browser tab has it).
    @ObservationIgnored private var workspaces: [ObjectIdentifier: String?] = [:]
    @ObservationIgnored private var chats = RoleLedger<Chat>()
    @ObservationIgnored private var browsers = RoleLedger<Browser>()
    /// The chat members by acpmux session; nil: blank chat records (a New Tab page restored as a chat).
    @ObservationIgnored private var bySession: [String?: Set<ObjectIdentifier>] = [:]
    /// Told, at each publish, the browser records whose role changed, by the object that follows.
    @ObservationIgnored private var browserFollowers: [ObjectIdentifier: @MainActor ([BrowserChange]) -> Void] = [:]

    /// A browser record whose role changed since the last publish: the record now (nil: it is no longer a browser
    /// tab of this store, or no longer listed).
    public struct BrowserChange {
        public let record: ObjectIdentifier
        public let tab: TabModel?
    }

    public init() {}

    /// Every agent chat tab record the store lists (a blank chat record too), by tab id: a tab two
    /// records hold during a move is listed once per record. Observes ``chatRevision`` only.
    public var chatTabs: [TabModel] {
        _ = chatRevision
        return members(chats.current.keys)
    }

    /// The agent chat tab records that show acpmux session `session` (nil: the blank chat records, with no session
    /// yet), by tab id. Costs the records it returns. Observes ``chatRevision`` only.
    public func chatTabs(showing session: String?) -> [TabModel] {
        _ = chatRevision
        return members(bySession[session] ?? [])
    }

    /// Every browser tab record the store lists, by tab id. Observes ``browserRevision`` only.
    public var browserTabs: [TabModel] {
        _ = browserRevision
        return members(browsers.current.keys)
    }

    /// Tells `onChange` the browser records each publish changed (listed, dropped, or a new address or favicon),
    /// until ``stopFollowingBrowsers(_:)`` with the same `follower`: an index of them keeps itself by these, never
    /// by a walk of the tree. A second call for the same follower replaces its closure. Read ``browserTabs`` first.
    public func followBrowsers(_ follower: AnyObject, _ onChange: @escaping @MainActor ([BrowserChange]) -> Void) {
        browserFollowers[ObjectIdentifier(follower)] = onChange
    }

    public func stopFollowingBrowsers(_ follower: AnyObject) {
        browserFollowers[ObjectIdentifier(follower)] = nil
    }

    /// The workspace (`WorkspaceModel.id`) that holds browser tab `tab`, as the index last filed it; nil for a tab
    /// that is not a browser tab of this store. Observes ``browserRevision`` only (a browser tab that moves to
    /// another workspace moves it).
    public func workspaceID(ofBrowser tab: TabModel) -> String? {
        _ = browserRevision
        return browsers.current[ObjectIdentifier(tab)]?.workspace
    }

    /// How many records each role lists now (tests and debug counters).
    public var counts: (chats: Int, browsers: Int) { (chats.current.count, browsers.current.count) }

    /// The records of `ids`, by tab id (a stable order the tree's order does not cost).
    private func members<S: Sequence<ObjectIdentifier>>(_ ids: S) -> [TabModel] {
        ids.compactMap { records[$0] }.sorted { $0.id < $1.id }
    }

    // MARK: StoreIndex and TabModel hooks

    /// `tab` was keyed (`workspace`: the workspace that holds it), or a field a role reads changed (`workspace`
    /// nil: the one it was keyed in): files it under the roles it has now.
    // perf-hot: 1us store-tab-roles (every tab keyed by an apply, and every kind, conversation, url or favicon change)
    func note(_ tab: TabModel, workspace: String?? = nil) {
        let id = ObjectIdentifier(tab)
        if let workspace { workspaces[id] = workspace }
        let chat = tab.agentSession.map { Chat(id: tab.id, session: $0.session) }
        let browser = tab.kind == .browser ? Browser(id: tab.id, url: tab.url, favicon: tab.faviconURL, workspace: workspaces[id] ?? nil) : nil
        // A terminal that was in no role (most tabs) costs this check only.
        guard chat != nil || browser != nil || records[id] != nil else { return }
        records[id] = chat != nil || browser != nil ? tab : nil
        file(id, chat: chat)
        browsers.set(id, browser)
    }

    /// `tab` was dropped from the index.
    // perf-hot: 1us store-tab-roles (every tab dropped by an apply)
    func drop(_ tab: TabModel) {
        let id = ObjectIdentifier(tab)
        workspaces[id] = nil
        guard records.removeValue(forKey: id) != nil else { return }
        file(id, chat: nil)
        browsers.set(id, nil)
    }

    /// The index starts over (``StoreIndex/rebuild(_:)``): each record keeps the roles it had at the
    /// last publish, so the next publish reports only what the rebuild changed.
    func noteRebuildStarted() {
        for id in Array(records.keys) { file(id, chat: nil); browsers.set(id, nil) }
        records.removeAll(keepingCapacity: true)
        workspaces.removeAll(keepingCapacity: true)
    }

    /// The store published its tab list: moves each role's revision once when its set changed.
    // perf-hot: 1us store-tab-roles (every apply and intent; costs the records touched since the last publish)
    func publish() {
        if !chats.takeChanges().isEmpty { chatRevision &+= 1 }
        let changed = browsers.takeChanges()
        guard !changed.isEmpty else { return }
        if !browserFollowers.isEmpty {
            let changes = changed.map { BrowserChange(record: $0, tab: browsers.current[$0] == nil ? nil : records[$0]) }
            for onChange in browserFollowers.values { onChange(changes) }
        }
        browserRevision &+= 1
    }

    private func file(_ id: ObjectIdentifier, chat: Chat?) {
        let old = chats.current[id]
        chats.set(id, chat)
        guard old != chat else { return }
        if let old {
            bySession[old.session]?.remove(id)
            if bySession[old.session]?.isEmpty == true { bySession[old.session] = nil }
        }
        if let chat { bySession[chat.session, default: []].insert(id) }
    }
}

/// One role's members and, for each member touched since the last publish, what it was at that publish.
private struct RoleLedger<Value: Equatable> {
    var current: [ObjectIdentifier: Value] = [:]
    /// The value at the last publish of each record touched since (nil inside: not a member then).
    private var published: [ObjectIdentifier: Value?] = [:]

    mutating func set(_ id: ObjectIdentifier, _ value: Value?) {
        if published[id] == nil { published.updateValue(current[id], forKey: id) }
        current[id] = value
    }

    /// The records touched since the last publish whose value differs from what it was then; starts over.
    mutating func takeChanges() -> [ObjectIdentifier] {
        defer { published.removeAll(keepingCapacity: true) }
        return published.compactMap { $0.value != current[$0.key] ? $0.key : nil }
    }
}

public import CmuxNextDaemon
public import CmuxNextSidebar

/// One app's sidebar document (sidebar-v2, `sidebar-doc-v1`): its own store for the home session, the sections it
/// maps and its view over the machines' daemon stores. The app's composition root builds one and every reader reaches
/// it from there (PATTERNS.md P1): two apps in one process (tests) never share a document.
@MainActor
public final class SidebarDocument {
    /// The home session's store: nil until the app starts it, and on an app whose test set its own layout owner; a
    /// test may set a fixture store.
    public var store: SidebarDocStore?
    /// The document's machine nodes as the daemon-level sections the sidebar maps (one group model per document group).
    public private(set) lazy var docSections = SidebarDocSections(document: { [weak self] in self?.store })
    private let stores: @MainActor () -> [DaemonStore]
    private let machine: @MainActor (String) -> DaemonStore?

    /// `stores`: every machine's store, the local one first; `machine`: the store of a machine id.
    public init(stores: @escaping @MainActor () -> [DaemonStore], machine: @escaping @MainActor (String) -> DaemonStore?) {
        self.stores = stores
        self.machine = machine
    }

    /// This document over the machines' daemon stores.
    public var docMachines: SidebarDocMachines { SidebarDocMachines(document: { [weak self] in self?.store }, stores: stores, machine: machine) }
    /// The document is shown: band edits go to it, not to the older layout owner.
    public var isActive: Bool { store.map { $0.isActive && $0.shown != nil } ?? false }
    /// The store while it is shown (`isActive`), else nil.
    public var activeStore: SidebarDocStore? { isActive ? store : nil }
    /// The home session's spaces (`SidebarDocItem.owningRoom`): an item of a space that is gone lists in the default
    /// space. Nil until the home store mirrors its spaces (every stored space counts meanwhile, so none hides at launch).
    public var spaces: Set<String>? {
        guard let profiles = stores().first?.profiles, !profiles.isEmpty else { return nil }
        return Set(profiles.map(\.id.rawValue))
    }
    /// The document item that places sidebar workspace `id`.
    public func item(workspace id: String) -> String? { docMachines.item(workspace: id) }

    /// The document has applied a change `shown` does not show yet (rebuilt a hop later), and `shown` does not place
    /// `workspace` (of `session`): `sections` would list it after every placed row for that hop. Only while `shown`
    /// lags: a workspace a current projection does not place (its adopt still on the way, or refused) lists its own
    /// row, so a pending row never stands in for it for long.
    public func awaitsPlacement(_ workspace: WorkspaceModel, session: String?) -> Bool {
        guard let store, let shown = store.shown, store.version != store.shownVersion,
              let ref = SidebarDocSections.ref(of: workspace, session: session) else { return false }
        return shown.items[ref] == nil
    }
}

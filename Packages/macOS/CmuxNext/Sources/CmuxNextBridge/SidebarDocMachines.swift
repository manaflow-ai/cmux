import CmuxNextCompat
public import CmuxNextDaemon
public import CmuxNextSidebar
public import Foundation

/// The sidebar document (sidebar-v2, `sidebar-doc-v1`) over the machines' daemon stores: the workspace refs it places,
/// the item of a sidebar workspace, the drag half and the move intents, and the store's live follow. The app hands its
/// machine registry in as reads (moved from CmuxNextApp's SidebarDocWiring, SW14). Nothing here runs without the
/// document: every entry point checks the store first.
@MainActor
public struct SidebarDocMachines {
    private let document: @MainActor () -> SidebarDocStore?
    private let stores: @MainActor () -> [DaemonStore]
    private let machine: @MainActor (String) -> DaemonStore?

    /// `document`: the app's own document store (nil before it starts); `stores`: every machine's store, the local one
    /// first; `machine`: the store of a machine id.
    public init(document: @escaping @MainActor () -> SidebarDocStore?, stores: @escaping @MainActor () -> [DaemonStore],
                machine: @escaping @MainActor (String) -> DaemonStore?) {
        self.document = document
        self.stores = stores
        self.machine = machine
    }

    /// Every live workspace's document ref.
    public func liveRefs() -> [SidebarDocWorkspaceRef] {
        stores().flatMap { store in store.workspaces.compactMap { SidebarDocSections.ref(of: $0, session: store.registryID) } }
    }

    /// The workspace `id` and the store holding it (the local store first).
    private func workspace(id: String) -> (WorkspaceModel, DaemonStore)? {
        stores().lazy.compactMap { store in store.workspace(id: id).map { ($0, store) } }.first
    }

    /// The confirmed document item that places sidebar workspace `id`. A workspace only a pending change places (its
    /// adopt still on the way) has none: a later change names it by its adopt again (`adoptRef`), so it does not depend
    /// on the earlier change reaching the daemon first (a pin, an archive, a drag or a reorder right after Cmd-N).
    public func item(workspace id: String) -> String? {
        guard let store = document(), let (workspace, daemon) = workspace(id: id),
              let ref = SidebarDocSections.ref(of: workspace, session: daemon.registryID),
              let item = store.shown?.items[ref], store.records.items[item] != nil else { return nil }
        return item
    }

    /// The drag half while the document is active.
    public func drag() -> SidebarDocDrag? {
        guard let store = document(), store.isActive, store.shown != nil else { return nil }
        return SidebarDocDrag(document: store, item: { key in
            switch key {
            case .workspace(let id): item(workspace: id.rawValue)
            case .group(let group): group.rawValue
            default: nil
            }
        }, section: { id in
            switch id {
            case .pinned, .custom: SidebarDocStore.pinnedSection // SidebarDocDrag answers .custom itself
            case .machine(let machine): self.machine(machine.rawValue)?.registryID.flatMap { store.shown?.machineSections[$0] }
            }
        }, begin: { store.acceptance(dragging: $0) }, drop: { store.move($0, to: $1, title: SidebarDocStore.moveTitle) }, adoptRef: { id in
            guard let (workspace, daemon) = workspace(id: id.rawValue), let ref = SidebarDocSections.ref(of: workspace, session: daemon.registryID) else { return nil }
            return ["session_id": ref.sessionID, "workspace_id": ref.workspaceID, "workspace_key": workspace.key?.rawValue ?? workspace.id]
        })
    }

    /// Sends a move intent as one document move. False: not a move, or the
    /// document is not active (the older path handles it).
    public func handle(_ intent: SidebarIntent, model: SidebarModel, pinTitle: String, unpinTitle: String, undoable: Bool = true) -> Bool {
        guard let store = document(), let drag = drag() else { return false }
        return store.handle(intent, model: model, drag: drag, pinTitle: pinTitle, unpinTitle: unpinTitle, undoable: undoable)
    }

    /// Places ids at the list position in the document in the same turn as their create.
    /// False leaves the older reorder path in charge when the document is inactive.
    public func place(_ ids: [WorkspaceID], at position: DropPosition, model: SidebarModel) -> Bool {
        guard let store = document(), let drag = drag(),
              store.handle(.reorder(ids, to: position), model: model, drag: drag,
                           pinTitle: SidebarDocStore.moveTitle, unpinTitle: SidebarDocStore.moveTitle, undoable: false)
        else { return false }
        // The reducer mirror is updated synchronously, but the normal Observation stream redraws one actor hop later.
        // Rebuild now so a just-adopted workspace cannot render in the document's unplaced tail first.
        store.reshow(live: liveRefs())
        return true
    }

    /// Keeps `store` current: it refreshes when the home daemon connects or starts serving the document, and it shows
    /// the live workspaces (`connectedRemotes`: the sessions of the connected remote machines) after each document or
    /// live-set change; `shown` gets the band layout it shows.
    public func follow(_ store: SidebarDocStore, connected: @escaping @MainActor () -> Bool, serves: @escaping @MainActor () -> Bool,
                       connectedRemotes: @escaping @MainActor () -> Set<String>, shown: @escaping @MainActor (SidebarLayoutDocument?) -> Void) {
        // task-owner: the app's services (live for the app); event-driven (Observation)
        Task { for await _ in ObservationStream({ (connected(), serves()) }) { store.refresh() } }
        // task-owner: the app's services; one view call per document or live-set change
        Task {
            // A trigger: a document change (`version`) with the same live set still redraws the bands.
            for await live in ObservationStream({ () -> ObservationTrigger<[SidebarDocWorkspaceRef]> in
                _ = (store.version, store.isActive)
                return ObservationTrigger(liveRefs())
            }) {
                store.show(live: live.value, connectedRemotes: connectedRemotes())
                shown(store.shown?.layout)
            }
        }
    }

    /// Draws the sidebar document the daemon's launch snapshot saved (`data`, `LaunchSnapshot.sidebarDoc`) now, in the
    /// turn the first window's sidebar seeds, so the Pinned band is in its first frame rather than after the daemon's
    /// `sidebar.get` (10.5 s after an update on a 41 GB registry, Lawrence 2026-10-29). `shown` gets its band layout.
    /// The daemon's first load replaces it; a daemon that connects without the document (`serves` false) drops it.
    public func showLaunchSnapshot(_ data: Data, in store: SidebarDocStore, connected: @escaping @MainActor () -> Bool,
                                   serves: @escaping @MainActor () -> Bool, shown: @MainActor (SidebarLayoutDocument?) -> Void) {
        guard store.loadProvisional(data) else { return }
        store.show(live: liveRefs())
        shown(store.shown?.layout)
        // task-owner: the app's services; ends at the first connection (event-driven, Observation)
        Task { [weak store] in
            for await isConnected in ObservationStream({ connected() }) where isConnected {
                if !serves() { store?.dropProvisional() }
                return
            }
        }
    }

    /// Link rows draw the favicon at their item's icon address. An open tab's favicon address can change while its image
    /// is cached already (no favicon `revision`): this watches the addresses too (`byOrigin`, one origin -> favicon table
    /// read once per change) and stores them on the link items; `faviconKey` is a page's origin key.
    public static func followFavicons(_ store: SidebarDocStore, revision: @escaping @MainActor () -> Int?,
                                      byOrigin: @escaping @MainActor () -> [String: String], faviconKey: @escaping (URL) -> String?) {
        // task-owner: the app's services (live for the app); event-driven (Observation)
        Task {
            var last: [String: String]?
            var lastVersion: UInt64?
            for await (_, version, origins) in ObservationStream({ (revision(), store.version, byOrigin()) }) {
                NotificationCenter.default.post(name: SidebarModel.itemFaviconsChanged, object: nil)
                guard origins != last || version != lastVersion else { continue } // a tab change that moves no favicon address
                (last, lastVersion) = (origins, version)
                store.storeIconURLs { page in URL(string: page).flatMap(faviconKey).flatMap { origins[$0] } }
            }
        }
    }
}

extension SidebarDocSections {
    /// Every workspace of `store` in the document's order (window membership order), whatever its room; nil off the
    /// document path.
    public func orderedIDs(of store: DaemonStore, unplacedOrder: ([WorkspaceModel]) -> [WorkspaceModel] = { $0 }) -> [String]? {
        guard let doc = document(), doc.isActive, let shown = doc.shown, let session = store.registryID else { return nil }
        let listed = sections(shown, session: session, workspaces: store.workspaces, unplacedOrder: unplacedOrder).flatMap(\.workspaces).map(\.id)
        let seen = Set(listed)
        return listed + store.workspaces.map(\.id).filter { !seen.contains($0) }
    }
}

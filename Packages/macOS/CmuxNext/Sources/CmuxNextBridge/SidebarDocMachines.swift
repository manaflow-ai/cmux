import CmuxNextCompat
public import CmuxNextDaemon
public import CmuxNextSidebar
public import CmuxNextWakeups
public import Foundation

/// The sidebar document (sidebar-v2, `sidebar-doc-v1`) over the machines' daemon stores: the workspace refs it places,
/// the item of a sidebar workspace, the drag half and the move intents, and the store's live follow. The app hands its
/// machine registry in as reads (moved from CmuxNextApp's SidebarDocWiring, SW14). Nothing here runs without the
/// document: every entry point checks the store first.
@MainActor
public struct SidebarDocMachines {
    private let stores: @MainActor () -> [DaemonStore]
    private let machine: @MainActor (String) -> DaemonStore?

    /// `stores`: every machine's store, the local one first; `machine`: the store of a machine id.
    public init(stores: @escaping @MainActor () -> [DaemonStore], machine: @escaping @MainActor (String) -> DaemonStore?) {
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
        guard let store = SidebarDocStore.current, let (workspace, daemon) = workspace(id: id),
              let ref = SidebarDocSections.ref(of: workspace, session: daemon.registryID),
              let item = store.shown?.items[ref], store.records.items[item] != nil else { return nil }
        return item
    }

    /// The drag half while the document is active.
    public func drag() -> SidebarDocDrag? {
        guard let store = SidebarDocStore.current, store.isActive, store.shown != nil else { return nil }
        return SidebarDocDrag(item: { key in
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
        guard let store = SidebarDocStore.current, let drag = drag() else { return false }
        return store.handle(intent, model: model, drag: drag, pinTitle: pinTitle, unpinTitle: unpinTitle, undoable: undoable)
    }

    /// Keeps `store` current: it refreshes when the home daemon connects or starts serving the document, and it shows
    /// the live workspaces (`connectedRemotes`: the sessions of the connected remote machines) after each document or
    /// live-set change; `shown` gets the band layout it shows (after its last chunk when the store shows in chunks).
    /// Returns the follows (``ServiceObservation``s on `work`, class visible: the document and its bands are model state
    /// the sidebar shows, and they must follow while no window shows a sidebar); the caller keeps them for the app's
    /// life, and releasing them stops the follows.
    public func follow(_ store: SidebarDocStore, connected: @escaping @MainActor () -> Bool, serves: @escaping @MainActor () -> Bool,
                       connectedRemotes: @escaping @MainActor () -> Set<String>, shown: @escaping @MainActor (SidebarLayoutDocument?) -> Void,
                       on work: MainWorkScheduler) -> [AnyObject] {
        // A tuple: every change of either refreshes (no dedupe), as the loop it replaced did.
        let link = ServiceObservation(.visible, owner: "SidebarDocMachines.link", on: work) {
            (connected: connected(), serves: serves())
        } apply: { _ in
            store.refresh()
        }
        // A trigger: a document change (`version`) with the same live set still redraws the bands.
        let bands = ServiceObservation(.visible, owner: "SidebarDocMachines.bands", on: work) { () -> ObservationTrigger<[SidebarDocWorkspaceRef]> in
            _ = (store.version, store.isActive)
            return ObservationTrigger(liveRefs())
        } apply: { live in
            store.show(live: live.value, connectedRemotes: connectedRemotes()) { shown($0?.layout) }
        }
        return [link, bands]
    }

    /// Link rows draw the favicon at their item's icon address. An open tab's favicon address can change while its image
    /// is cached already (no favicon `revision`): this watches the addresses too (`byOrigin`, one origin -> favicon table
    /// read once per change) and stores them on the link items; `faviconKey` is a page's origin key. The returned
    /// ``ServiceObservation`` (visible, on `work`) is the follow: the app keeps it for its life; a test releases its own.
    public static func followFavicons(_ store: SidebarDocStore, revision: @escaping @MainActor () -> Int?,
                                      byOrigin: @escaping @MainActor () -> [String: String],
                                      faviconKey: @escaping (URL) -> String?, on work: MainWorkScheduler) -> AnyObject {
        var last: [String: String]?
        var lastVersion: UInt64?
        // A tuple: each favicon revision tells the lists, whether or not an address moved.
        return ServiceObservation(.visible, owner: "SidebarDocMachines.favicons", on: work) {
            (revision: revision(), version: store.version, origins: byOrigin())
        } apply: { state in
            store.faviconsChanged() // every list draws its link rows again
            guard state.origins != last || state.version != lastVersion else { return } // a tab change that moves no favicon address
            (last, lastVersion) = (state.origins, state.version)
            store.storeIconURLs { page in URL(string: page).flatMap(faviconKey).flatMap { state.origins[$0] } }
        }
    }
}

extension SidebarDocSections {
    /// Every workspace of `store` in the document's order (window membership order), whatever its room; nil off the
    /// document path.
    public func orderedIDs(of store: DaemonStore, unplacedOrder: ([WorkspaceModel]) -> [WorkspaceModel] = { $0 }) -> [String]? {
        guard let doc = SidebarDocStore.current, doc.isActive, let shown = doc.shown, let session = store.registryID else { return nil }
        let listed = sections(shown, session: session, workspaces: store.workspaces, unplacedOrder: unplacedOrder).flatMap(\.workspaces).map(\.id)
        let seen = Set(listed)
        return listed + store.workspaces.map(\.id).filter { !seen.contains($0) }
    }
}

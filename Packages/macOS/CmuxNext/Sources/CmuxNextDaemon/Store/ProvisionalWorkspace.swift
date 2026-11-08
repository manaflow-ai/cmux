import Foundation

/// A workspace a create intent shows before the daemon has it (Cmd-N, instant-new-surfaces):
/// one screen, one pane, one tab, under the key the create sends. Its handles live far above the
/// daemon's (and above ``ProvisionalPane``'s), so none can name a daemon object; its key is the
/// workspace key `create-workspace` sends, so the daemon's workspace is recognized by it and
/// takes over the same `WorkspaceModel` in place (``DaemonStore/confirmedWorkspace(_:)``): the
/// window that shows it keeps its content.
public struct ProvisionalWorkspace: Sendable, Hashable {
    /// Above ProvisionalPane's range (`1 << 62` up), below `UInt64.max`.
    private static let handleBase: UInt64 = (1 << 62) | (1 << 61)
    @MainActor private static var next: UInt64 = 0

    /// The key `create-workspace` sends; the workspace's id in the store.
    public let key: WorkspaceKey
    /// The name the create sends, shown from the first frame.
    public let name: String
    public let handle: WorkspaceHandle
    public let screen: ScreenID
    public let pane: PaneID
    /// The first tab (a provisional conversation tab: the New Tab page), replaced by the
    /// daemon's tab on its transaction's echo or reply (`ProvisionalTab.created`).
    public let tab: TabSnapshot

    /// A fresh provisional workspace with first tab `tab` (``ProvisionalTab/conversation(_:)``).
    @MainActor public init(key: WorkspaceKey, name: String, tab: TabSnapshot) {
        Self.next += 1
        let id = Self.handleBase + Self.next * 4
        self.key = key
        self.name = name
        handle = WorkspaceHandle(rawValue: id)
        screen = ScreenID(rawValue: id + 1)
        pane = PaneID(rawValue: id + 2)
        self.tab = tab
    }

    private init(key: WorkspaceKey, name: String, handle: WorkspaceHandle, screen: ScreenID, pane: PaneID, tab: TabSnapshot) {
        self.key = key
        self.name = name
        self.handle = handle
        self.screen = screen
        self.pane = pane
        self.tab = tab
    }

    /// The same workspace (key, handles, first tab) under the name `name`: the name a press of the key gives the
    /// workspace it reserved before the key (``DaemonStore/reserveWorkspace(_:)``).
    public func named(_ name: String) -> ProvisionalWorkspace {
        ProvisionalWorkspace(key: key, name: name, handle: handle, screen: screen, pane: pane, tab: tab)
    }

    /// Whether `handle` is a provisional workspace's (never a daemon workspace).
    public static func isProvisional(_ handle: WorkspaceHandle) -> Bool { handle.rawValue >= handleBase }

    /// The workspace record the overlay shows when the daemon has none yet.
    var workspaceSnapshot: WorkspaceSnapshot {
        WorkspaceSnapshot(id: handle, key: key, name: name, nameSource: .user, screens: [])
    }

    /// The screen the overlay shows until the daemon's workspace holds a tab.
    var screenSnapshot: ScreenSnapshot {
        ScreenSnapshot(id: screen, active: true, activePane: pane, layout: .leaf(pane),
                       panes: [PaneSnapshot(id: pane, tabs: [tab])])
    }
}

/// The one model and screen of each pending workspace create, by key: every overlay restore shows
/// the same objects, and the daemon's workspace takes the model over in place.
struct ProvisionalWorkspaceModels {
    var workspacesByID: [String: WorkspaceModel] = [:]
    var screensByID: [String: ScreenModel] = [:]
    /// The next Cmd-N's workspace, made before its key (``DaemonStore/reserveWorkspace(_:)``). Its own field: the
    /// prune of settled creates (`releaseSettledProvisionalWorkspaces`) keeps only keys a pending create names.
    var reserved: ReservedWorkspace?
    /// Memory pressure: nothing is reserved until it is normal again.
    var paused = false
}

/// The next Cmd-N's workspace, made before the key, as Chrome keeps a spare renderer (STATUS 15250): its model holds
/// its screen, so a window builds the workspace's view before the key, and the key's create intent shows this model
/// (``ProvisionalWorkspaceOverlay``). Never in `workspaces`, the index or the sidebar until that intent applies.
public struct ReservedWorkspace {
    /// The workspace the press shows (its name is the press's: ``ProvisionalWorkspace/named(_:)``).
    public let provisional: ProvisionalWorkspace
    /// The model the window builds its view on; the create intent shows this one object.
    public let model: WorkspaceModel
    let screen: ScreenModel
    /// Its first tab's key (the provisional tab id), under which the app keeps its page.
    public var tabKey: String? { provisional.tab.tabResourceID?.rawValue }
}

/// What a press of Cmd-N does with its daemon's reservation; ``span`` names it for the bench (`cmdN.reserved.*`).
public enum ReservedWorkspaceUse: Equatable, Sendable {
    /// The press shows the reserved workspace under this key.
    case hit(WorkspaceKey)
    /// No reservation on the press's daemon; `elsewhere`: the home daemon holds one (the press went to another).
    case miss(elsewhere: Bool)
    /// Not a plain Cmd-N: it never takes a reservation.
    case notPlain

    public var key: WorkspaceKey? {
        guard case .hit(let key) = self else { return nil }
        return key
    }

    public var span: String? {
        switch self {
        case .hit: "cmdN.reserved.hit"
        case .miss(let elsewhere): elsewhere ? "cmdN.reserved.miss.daemon" : "cmdN.reserved.miss.none"
        case .notPlain: nil
        }
    }
}

/// Why a reservation went (its bench span `cmdN.reserved.released.<reason>`).
public enum ReservedWorkspaceRelease: String, Sendable {
    /// Warning or critical memory pressure.
    case pressure
    /// A press took its key but did not show it (the key never names another workspace).
    case unshown

    public var span: String { "cmdN.reserved.released.\(rawValue)" }
}

extension DaemonStore {
    /// The models of Cmd-N's pending workspace creates (kept with the intent log they belong to).
    var provisionalWorkspaces: ProvisionalWorkspaceModels {
        get { intentLog.workspaceModels }
        set { intentLog.workspaceModels = newValue }
    }

    /// The reserved next Cmd-N workspace, if any.
    public var reservedWorkspace: ReservedWorkspace? { provisionalWorkspaces.reserved }

    /// Memory pressure pauses reserving (the caller lets the reservation go); normal pressure resumes it.
    public var reservationPaused: Bool {
        get { provisionalWorkspaces.paused }
        set { provisionalWorkspaces.paused = newValue }
    }

    /// The reserved workspace when a press sends its key `key`.
    public func reservedWorkspace(keyed key: WorkspaceKey) -> ReservedWorkspace? {
        provisionalWorkspaces.reserved.flatMap { $0.provisional.key == key ? $0 : nil }
    }

    /// Whether `model` is this store's reserved workspace (a view built on another one is stale).
    public func reserves(_ model: WorkspaceModel) -> Bool { provisionalWorkspaces.reserved?.model === model }

    /// What a press on this daemon does with the reservation: `plain` (a plain Cmd-N into a window that shows its
    /// workspace before the daemon) takes it; `home` is the app's own daemon, to tell a miss there from none.
    public func reservedWorkspaceUse(plain: Bool, home: DaemonStore) -> ReservedWorkspaceUse {
        guard plain else { return .notPlain }
        guard let reserved = provisionalWorkspaces.reserved else { return .miss(elsewhere: home !== self && home.reservedWorkspace != nil) }
        return .hit(reserved.provisional.key)
    }

    /// Reserves `provisional` as the next Cmd-N's workspace (replacing an earlier reservation): its model and screen are
    /// made now, the screen inside the model, outside the store's workspaces, index and sidebar.
    @discardableResult
    public func reserveWorkspace(_ provisional: ProvisionalWorkspace) -> ReservedWorkspace {
        let model = WorkspaceModel(provisional.workspaceSnapshot), screen = ScreenModel(provisional.screenSnapshot)
        model.screens = [screen]
        let reserved = ReservedWorkspace(provisional: provisional, model: model, screen: screen)
        provisionalWorkspaces.reserved = reserved
        return reserved
    }

    /// Lets the reservation go for `reason` and returns it (nil: there was none). Nothing of it was shown or sent.
    @discardableResult
    public func releaseReservedWorkspace(_ reason: ReservedWorkspaceRelease) -> ReservedWorkspace? {
        defer { provisionalWorkspaces.reserved = nil }
        return provisionalWorkspaces.reserved
    }
}

/// The overlay of `Intent.createWorkspace`. Undone exactly. Three states, by what the confirmed
/// records hold under the key:
/// - nothing: the provisional workspace (its one model) is inserted with its screen;
/// - the daemon's workspace without a tab (`create-workspace` answered, the first tab not yet):
///   the provisional screen is shown inside it, so the window never draws an empty workspace;
/// - the daemon's workspace with a tab: nothing (the intent has nothing left to show).
@MainActor struct ProvisionalWorkspaceOverlay {
    static func apply(_ provisional: ProvisionalWorkspace, index: Int?, to store: DaemonStore) -> IntentUndo? {
        // The press of a reserved workspace shows the model its window built a view on, named as the press names it.
        if let reserved = store.provisionalWorkspaces.reserved, reserved.provisional.key == provisional.key {
            store.provisionalWorkspaces.reserved = nil
            reserved.model.name = provisional.name
            store.provisionalWorkspaces.workspacesByID[provisional.key.rawValue] = reserved.model
            store.provisionalWorkspaces.screensByID[provisional.key.rawValue] = reserved.screen
        }
        let model = store.provisionalWorkspaces.workspacesByID[provisional.key.rawValue]
        let confirmed = store.workspacesByKey[provisional.key]
        if let confirmed, confirmed.screens.contains(where: { $0.panes.contains { !$0.tabs.isEmpty } }) { return nil }
        if confirmed == nil, store.tabsBySurface[provisional.tab.surface] != nil { return nil }
        var inserted = false
        let workspace: WorkspaceModel
        if let confirmed {
            workspace = confirmed
        } else {
            workspace = model ?? WorkspaceModel(provisional.workspaceSnapshot)
            store.provisionalWorkspaces.workspacesByID[provisional.key.rawValue] = workspace
            let at = min(max(index ?? store.workspaces.count, 0), store.workspaces.count)
            store.workspaces.insert(workspace, at: at)
            store.index.insert(workspace)
            store.sidebarNeedsRecompute = true
            inserted = true
        }
        let screen = store.provisionalWorkspaces.screensByID[provisional.key.rawValue] ?? ScreenModel(provisional.screenSnapshot)
        store.provisionalWorkspaces.screensByID[provisional.key.rawValue] = screen
        // A reserved model already holds its screen (an undo took it out of every other).
        if !workspace.screens.contains(where: { $0 === screen }) { workspace.screens.append(screen) }
        store.indexed(screen, in: workspace)
        return .createdWorkspace(key: provisional.key, inserted: inserted)
    }

    /// The daemon's pane that took Cmd-N's stand-in pane over: in the daemon's workspace `key`, the pane that holds the
    /// daemon's first tab (the New Tab page the stand-in showed), so a create pressed on the stand-in lands where it was
    /// pressed, after that page. Before the first tab is known (or once it left), the screen's active pane that holds a
    /// daemon tab. Nil while the daemon's workspace holds no tab yet (the stand-in still shows).
    static func adoptedPane(of key: WorkspaceKey, in store: DaemonStore) -> PaneID? {
        guard let workspace = store.workspacesByKey[key], !workspace.isProvisional else { return nil }
        func adopted(_ pane: PaneModel) -> Bool {
            pane.handle.rawValue < ProvisionalPane.firstHandle && pane.tabs.contains { !ProvisionalTab.isProvisional(surface: $0.surface) }
        }
        if let firstTab = firstTab(of: key, workspace: workspace, in: store), let tab = store.tabsBySurface[firstTab],
           let pane = store.pane(holding: tab), adopted(pane) {
            return pane.handle
        }
        let screens = workspace.screens.filter(\.isActive) + workspace.screens.filter { !$0.isActive }
        for screen in screens {
            if let active = screen.panes.first(where: { $0.handle == screen.defaultPane }), adopted(active) { return active.handle }
            if let pane = screen.panes.first(where: adopted) { return pane.handle }
        }
        return nil
    }

    /// The daemon's surface of Cmd-N's first tab for workspace `key`: its pending intent's confirmed created tab, or
    /// what the workspace recorded when that intent left the log.
    private static func firstTab(of key: WorkspaceKey, workspace: WorkspaceModel, in store: DaemonStore) -> SurfaceID? {
        for entry in store.intentLog.entries {
            if case .createWorkspace(let provisional, _) = entry.kind, provisional.key == key {
                return entry.createdConfirmed ? entry.createdSurface : nil
            }
        }
        return workspace.tookOverStandIn?.firstTab
    }

    static func undo(key: WorkspaceKey, inserted: Bool, in store: DaemonStore) {
        guard let workspace = store.workspacesByKey[key] ?? store.provisionalWorkspaces.workspacesByID[key.rawValue] else {
            return store.reportMirrorViolation("intent overlay undo found workspace \(key) missing")
        }
        if let screen = store.provisionalWorkspaces.screensByID[key.rawValue] {
            store.index.remove(screen)
            workspace.screens.removeAll { $0 === screen }
        }
        guard inserted else { return }
        store.index.remove(workspace)
        store.workspaces.removeAll { $0 === workspace }
        store.sidebarNeedsRecompute = true
    }
}

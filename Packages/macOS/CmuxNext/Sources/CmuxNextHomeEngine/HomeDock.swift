import CmuxNextCompat
public import CmuxNextDaemon
import CmuxNextDesign
public import CmuxNextHome
public import Foundation
import os

/// Home as a workspace with a left dock (hq-6d Home workspace, cx-ebm.59.5; Lawrence 2026-10-14:
/// "we can use docked left column to be the home but right side should be a workspace"). The
/// store's home workspace holds ONE page tab, the app's `home-dock` page (the native Messages view, the
/// sidebar's Home entry, or hq-ec's `home-channels` page, its Channels entry while Channels is enabled;
/// Lawrence 2026-10-14: "bring imessage chief back by default instead of slack"), in a LEFT dock column with
/// the agent chat role: the same daemon dock Cmd-I opens (cx-ihyx2), never a second one.
/// Everything right of it is a normal workspace.
///
/// The app only asks, on every connect: one keyed `new-conversation-tab` for the page when the
/// home has none, then one `move-tab-to-column` with `dock` when its column is not that dock. Both
/// read the tree first, so two windows or a reconnect never duplicate the tab or the dock. A home
/// from before (the Chief conversation tab, no dock) migrates on its first connect: its Chief tab
/// closes (the page shows the Chief conversation) and the page moves into the dock; the docked
/// `home-channels` tab of the home before the switch closes the same way. When nothing
/// else would stay on the right, the move leaves a terminal there in the same daemon commit: the
/// daemon undocks a screen without a scrolling column.
@MainActor
public final class HomeDock {
    /// The page tab the dock holds: the Messages and Channels views of Home.
    public static let page = "home-dock"
    /// The page tab the dock held before the two views (hq-ec's `home-channels` page alone).
    static let legacyPage = "home-channels"
    /// Classic Home for one release (`labs.classicHome`): the top page, with the Chief tab in the
    /// hidden home workspace. `CMUX_NEXT_CLASSIC_HOME=1` at launch selects it too (GUI tests of the
    /// native Home). Both are read once, at the first read after launch (the settings file is applied
    /// before any window or Home starts): a change takes effect after cmux restarts, so Home is
    /// never half docked (the dock ensure runs only on connects; a live flip would leave the old
    /// form's tabs and refuse Home's actions).
    public static var classic: Bool { latched }
    private static let latched: Bool = DesignSettings.shared.classicHome || classicAtLaunch
    /// `CMUX_NEXT_CLASSIC_HOME=1` in the app's launch environment, read once.
    static let classicAtLaunch = ProcessInfo.processInfo.environment["CMUX_NEXT_CLASSIC_HOME"] == "1"
    public var isClassic: Bool { Self.classic }
    /// The origin of the page tab's creation key.
    static let origin = "cmux-next-home-dock"

    /// Moves a tab into a new left dock with the agent chat role on its anchor pane's screen,
    /// leaving `respawn` in the pane it left: the app's `TabMoves.toNewDockColumn`, which owns
    /// the dock width (`TabMoves.leftDockWidth`). Calls its completion once with the result.
    public typealias Dock = @MainActor (TabModel, PaneModel, SplitRespawn?, @escaping @MainActor (Bool) -> Void) -> Void

    /// One pending creation key, shared by overlapping connects; a closed page tab gets a new one.
    private let key = HomeChiefTabKey { "home-dock-page-\(UUID().uuidString.lowercased())" }
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")
    /// A dock move was sent and the tree does not show its dock yet: a connect meanwhile (launch
    /// runs this twice, a placed Chief again) must not send a second move.
    private var moveInFlight = false

    public init() {}

    /// The page tab of `home` and where it is, if any.
    public static func pageTab(in home: WorkspaceModel) -> (tab: TabModel, pane: PaneModel, screen: ScreenModel)? {
        for screen in home.screens {
            for pane in screen.panes {
                if let tab = pane.tabs.first(where: { $0.page == page }) { return (tab, pane, screen) }
            }
        }
        return nil
    }

    /// Whether `pane` is in a left dock column with the agent chat role on `screen`.
    static func isDocked(_ pane: PaneModel, on screen: ScreenModel) -> Bool {
        screen.columns.contains { column in
            column.dock?.edge == .left && column.dock?.role == .agentChat && column.layout.paneIDs.contains(pane.handle)
        }
    }

    /// One connect: the page tab in the home's left chat dock, and the home's Chief conversation
    /// tabs (tabs with a conversation source, which only Home creates there) gone, since the page
    /// shows the Chief conversation. Returns the step for `debug.home`; a failure is that step too
    /// (logged), so the Chief conversation's own setup still runs. Reads the home from the live
    /// tree each time (it changes while this waits).
    public func ensure(_ connection: DaemonConnection, store: DaemonStore, home: ResourceID, dock: Dock) async -> String {
        let needs = [DaemonCapabilities.shared.pageTabs, DaemonCapabilities.shared.dockColumnRole, DaemonCapabilities.shared.tabColumnRespawn]
        guard needs.allSatisfy({ store.supports($0) }) else { return "no home dock: the daemon lacks page tabs, dock roles or column respawn" }
        guard !moveInFlight else { return "home dock move in flight" }
        do {
            return try await ensureDock(connection, store: store, home: home, dock: dock)
        } catch {
            logger.error("home dock: \(String(describing: error), privacy: .public)")
            return "home dock failed: \(String(describing: error))"
        }
    }

    private func ensureDock(_ connection: DaemonConnection, store: DaemonStore, home: ResourceID, dock: Dock) async throws -> String {
        let workspace: @MainActor @Sendable () -> WorkspaceModel? = { store.workspaces.first { $0.resourceID == home } }
        guard let first = await shown(workspace) else { return "home workspace gone" }
        if Self.pageTab(in: first) == nil {
            // Always the workspace (its active pane, or a first pane of an empty home), so a
            // retry under the same key names the same target and replays.
            let handle = first.handle
            _ = try await key.ensure(chiefTabOpen: false) { mutationID in
                _ = try await connection.request(NewConversationTabRequest(page: Self.page, workspace: handle, origin: Self.origin,
                                                                           mutationID: mutationID))
            }
        } else {
            key.settle()
        }
        // The tree reports a just-created tab after its event.
        guard let placed = await shown({ workspace().flatMap(Self.pageTab(in:)) }), !Task.isCancelled else { return "page tab not shown" }
        let chiefs = Set((workspace()?.screens ?? []).flatMap { screen in
            screen.panes.flatMap { pane in pane.tabs.filter { Self.isChiefTab($0) || Self.isLegacyDockTab($0, in: pane, on: screen) } }
        }.map(\.surface))
        let docked = Self.isDocked(placed.pane, on: placed.screen)
        // What stays on the dock's screen once the page and the Chief tabs leave it: the daemon
        // undocks a screen without a scrolling column, so with nothing the move leaves a terminal.
        let stays = placed.screen.panes.flatMap(\.tabs).contains { $0.surface != placed.tab.surface && !chiefs.contains($0.surface) }
        if !chiefs.isEmpty, stays || !docked { try await connection.closeTabs(Array(chiefs), endTerminals: false) }
        if docked { return "home dock present" }
        let respawn: SplitRespawn? = stays ? nil : .terminal(SpawnOptions(workspace: workspace()?.key))
        moveInFlight = true
        defer { moveInFlight = false }
        let moved = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            dock(placed.tab, placed.pane, respawn) { done.resume(returning: $0) }
        }
        guard moved else { return "home dock move failed (see the app log)" }
        // Held until the tree shows the dock (or this run is cancelled), so a connect meanwhile reads it.
        _ = await shown { workspace().flatMap(Self.pageTab(in:)).flatMap { Self.isDocked($0.pane, on: $0.screen) ? true : nil } }
        return "home dock made"
    }

    /// A Chief conversation tab: a conversation tab whose source is a conversation (not a page or
    /// an agent session). In the home workspace only Home makes them (`new-conversation-tab`).
    static func isChiefTab(_ tab: TabModel) -> Bool {
        tab.kind == .conversation && tab.page == nil && tab.agentSession == nil && tab.snapshot.conversation?.conversation != nil
    }

    /// The old dock's `home-channels` page tab (before the switch): only one in the left chat dock,
    /// so a Channels tab the person opened on the right stays.
    static func isLegacyDockTab(_ tab: TabModel, in pane: PaneModel, on screen: ScreenModel) -> Bool {
        tab.page == legacyPage && isDocked(pane, on: screen)
    }

    /// The first non-nil value of `read`, observed; nil when cancelled first.
    private func shown<T: Sendable>(_ read: @escaping @MainActor @Sendable () -> T?) async -> T? {
        if let value = read() { return value }
        for await value in ObservationStream(read) { if let value { return value } }
        return nil
    }

    /// The sidebar's Home and Channels entries over a dock view (cx-frn2y): `shown` gets its view now and on
    /// each switch; for its life, `home.channelsEnabled` turned off (the palette, the CLI, a cmux.json edit)
    /// moves a shown Channels view to Messages, with the selection handed over (Disable selects Home).
    public static func followChannelsSetting(_ view: HomeDockSwitchView, shown: @escaping @MainActor (HomeDockMode) -> Void) {
        view.onShow = shown
        shown(view.mode)
        // task-owner: the dock view (cancelled by its close()); event-driven (Observation)
        view.tasks.append(Task { [weak view] in
            for await enabled in ObservationStream({ DesignSettings.shared.homeChannelsEnabled }) where !enabled {
                guard let view else { return }
                // Not only when Channels shows now: a switch to it in flight lands first, then this one (in order).
                view.switchTo(.messages)
            }
        })
    }

    /// A person's click on a web link in the Home page (cx-ebm.59.6): `workspace.open_url` on the
    /// app's own daemon connection, with no workspace (the home workspace). The daemon picks the
    /// pane and the tab; nothing is decided here. Other schemes open nothing, as before.
    public func openLink(_ url: URL, on connection: DaemonConnection?) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        guard let connection else {
            logger.error("home link: no daemon connection")
            return
        }
        let logger = logger
        // task-owner: one daemon request per click; it ends with the reply or the connection's timeout.
        Task {
            do { try await WorkspaceOpenURLClient(connection).openOnHome(url.absoluteString) } catch {
                logger.error("home link: workspace.open_url: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

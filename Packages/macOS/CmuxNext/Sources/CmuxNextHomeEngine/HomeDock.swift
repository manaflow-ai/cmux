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
/// else would stay on the right, the dock is made pinned in the same commit and stands alone
/// (`pinned-dock-alone-v1`; Leo 2026-10-19: "did we disable the initial thing auto opening a random
/// terminal pane on the right yet?"): Home opens with no right column until something is shown
/// there. Only an older daemon, which undocks a screen without a scrolling column, still gets a
/// terminal left on the right.
@MainActor
public final class HomeDock {
    /// The page tab the dock holds: the Messages and Channels views of Home.
    public static let page = WorkspaceModel.homeDockPage
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
    /// leaving `respawn` in the pane it left (none: the pane closes), pinned in the same commit when
    /// the flag is true: the app's `TabMoves.toNewDockColumn`, which owns the dock width
    /// (`TabMoves.leftDockWidth`). Calls its completion once with the result.
    public typealias Dock = @MainActor (TabModel, PaneModel, SplitRespawn?, Bool, @escaping @MainActor (Bool) -> Void) -> Void

    /// One pending creation key, shared by overlapping connects; a closed page tab gets a new one.
    private let key = HomeChiefTabKey { "home-dock-page-\(UUID().uuidString.lowercased())" }
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")
    /// A dock move was sent and the tree does not show its dock yet: a connect meanwhile (launch
    /// runs this twice, a placed Chief again) must not send a second move.
    private var moveInFlight = false
    /// The restored placeholder shell beside the dock was looked for: once per launch, and once
    /// ever (``placeholderCheckedKey``), so a shell the person opens there later, works in and
    /// leaves at `~` is never closed on a reconnect or a later launch.
    private var placeholderChecked = false
    private let defaults: UserDefaults
    /// Set once the first launch with `pinned-dock-alone-v1` looked for the placeholder shell.
    static let placeholderCheckedKey = "cmuxNext.home.placeholderShellChecked"
    /// Set once Home's pinned dock was let take tabs (``allowTabs``), so a dock the person later
    /// closes to tabs (`column.update {allow_tabs: false}`) stays as they set it.
    static let dockTakesTabsKey = "cmuxNext.home.dockTakesTabs"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

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
        dockColumn(pane, on: screen) != nil
    }

    /// One connect: the page tab in the home's left chat dock, and the home's Chief conversation
    /// tabs (tabs with a conversation source, which only Home creates there) gone, since the page
    /// shows the Chief conversation. Returns the step for `debug.home`; a failure is that step too
    /// (logged), so the Chief conversation's own setup still runs. Reads the home from the live
    /// tree each time (it changes while this waits).
    public func ensure(_ connection: DaemonConnection, store: DaemonStore, home: ResourceID, dock: Dock) async -> String {
        let needs = [DaemonCapability.pageTabs.rawValue, DaemonCapability.dockColumnRole.rawValue, DaemonCapability.tabColumnRespawn.rawValue]
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
        // A daemon that keeps a lone pinned dock: the dock is pinned in the move, and nothing is
        // left on its right (`pinned-dock-alone-v1`).
        let alone = store.supports(DaemonCapability.pinnedDock.rawValue) && store.supports(DaemonCapability.pinnedDockAlone.rawValue)
        // What stays on the dock's screen once the page and the Chief tabs leave it: an older
        // daemon undocks a screen without a scrolling column, so there the move leaves a terminal.
        let stays = placed.screen.panes.flatMap(\.tabs).contains { $0.surface != placed.tab.surface && !chiefs.contains($0.surface) }
        if !chiefs.isEmpty, stays || !docked { try await connection.closeTabs(Array(chiefs), endTerminals: false) }
        if docked {
            let pinned = try await pin(connection, store: store, workspace: workspace)
            let tabs = await allowTabsLogged(connection, store: store, workspace: workspace, fresh: pinned != nil)
            let cleared = alone ? try await closePlaceholder(connection, workspace: workspace) : nil
            let steps = [pinned, tabs, cleared].compactMap { $0 }
            return steps.isEmpty ? "home dock present" : steps.joined(separator: ", ")
        }
        let respawn: SplitRespawn? = stays || alone ? nil : .terminal(SpawnOptions(workspace: workspace()?.key))
        moveInFlight = true
        defer { moveInFlight = false }
        let moved = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            dock(placed.tab, placed.pane, respawn, alone) { done.resume(returning: $0) }
        }
        guard moved else { return "home dock move failed (see the app log)" }
        // Held until the tree shows the dock (or this run is cancelled), so a connect meanwhile reads it.
        _ = await shown { workspace().flatMap(Self.pageTab(in:)).flatMap { Self.isDocked($0.pane, on: $0.screen) ? true : nil } }
        _ = try await pin(connection, store: store, workspace: workspace)
        _ = await allowTabsLogged(connection, store: store, workspace: workspace, fresh: true)
        return "home dock made"
    }

    /// `pinned-dock-v1` (Lawrence 2026-10-18: "I should not be able to close Home inside the Home
    /// thing"): the dock becomes a pinned column with the page tab first, so the daemon keeps that tab
    /// (no close, move out or reorder away, for every client). ``allowTabs`` then lets the column take
    /// other tabs (Leo 2026-10-21). The column kind decides, never a title. Nil when there is nothing
    /// to do (pinned already, an older daemon, the dock not shown).
    private func pin(_ connection: DaemonConnection, store: DaemonStore,
                     workspace: @MainActor @Sendable () -> WorkspaceModel?) async throws -> String? {
        guard store.supports(DaemonCapability.pinnedDock.rawValue),
              let placed = workspace().flatMap(Self.pageTab(in:)),
              let dock = Self.dockColumn(placed.pane, on: placed.screen)?.dock, !dock.isPinned else { return nil }
        if placed.pane.tabs.first?.surface != placed.tab.surface {
            // The pinned tab is the column's first tab: the page goes first before the pin.
            _ = try await connection.moveTab(placed.tab.surface, to: placed.pane.handle, index: 0)
        }
        _ = try await connection.request(SetColumnDockRequest(pane: placed.pane.handle, dock: dock, pinned: true))
        return "home dock pinned"
    }

    /// Leo 2026-10-21: "JUST MAKE THE TAB THING SHOW UP ON THE MAIN PANE TOO". Home's pinned dock
    /// takes tabs (`allow_tabs`, `column.update`): its pane shows its tab strip like any pane, and a
    /// tab dragged onto it joins it and drags out again. The daemon still keeps the pinned page tab
    /// first and in the column. New tabs, splits and chats opened from Home still open beside it
    /// (`ChatColumnPlacement`, `NewChatPlacement`). A dock made or pinned now (`fresh`) always gets it;
    /// a dock pinned before gets it once (``dockTakesTabsKey``, kept per app install, not per
    /// daemon), so a person's later `allow_tabs: false` stays. Nil when there is nothing to do.
    /// ``allowTabs``, with a failure logged and returned as the step, so the rest of the connect
    /// (the placeholder check) still runs; the next connect tries again.
    private func allowTabsLogged(_ connection: DaemonConnection, store: DaemonStore,
                                 workspace: @MainActor @Sendable () -> WorkspaceModel?, fresh: Bool) async -> String? {
        do {
            return try await allowTabs(connection, store: store, workspace: workspace, fresh: fresh)
        } catch {
            logger.error("home dock allow_tabs: \(String(describing: error), privacy: .public)")
            return "home dock allow_tabs failed: \(String(describing: error))"
        }
    }

    private func allowTabs(_ connection: DaemonConnection, store: DaemonStore,
                           workspace: @MainActor @Sendable () -> WorkspaceModel?, fresh: Bool) async throws -> String? {
        guard store.supports(DaemonCapability.pinnedDock.rawValue), fresh || !defaults.bool(forKey: Self.dockTakesTabsKey),
              let placed = workspace().flatMap(Self.pageTab(in:)),
              let dock = Self.dockColumn(placed.pane, on: placed.screen)?.dock else { return nil }
        // A dock just pinned may not show its pin in the tree yet; the daemon has it (the pin replied).
        if dock.allowsTabs, dock.isPinned {
            defaults.set(true, forKey: Self.dockTakesTabsKey)
            return nil
        }
        guard let screen = placed.screen.resourceID, let pane = placed.pane.resourceID else {
            // The key stays unset, so the next connect tries again.
            logger.error("home dock allow_tabs: the tree has no resource id for the dock's screen or pane yet")
            return "home dock allow_tabs waits for resource ids"
        }
        try await connection.setColumnAllowsTabs(true, screen: screen, pane: pane)
        defaults.set(true, forKey: Self.dockTakesTabsKey)
        return "home dock takes tabs"
    }

    /// A home restored from before `pinned-dock-alone-v1` kept the terminal the dock move left on
    /// its right. A one-time migration: the first time a launch sees the docked Home, when that
    /// column holds nothing but such a shell (``isPlaceholderShell``), it closes and the dock stands
    /// alone; a column with anything real in it is kept as it was. Never again after that check.
    func closePlaceholder(_ connection: DaemonConnection,
                          workspace: @MainActor @Sendable () -> WorkspaceModel?) async throws -> String? {
        guard !placeholderChecked, !defaults.bool(forKey: Self.placeholderCheckedKey),
              let placed = workspace().flatMap(Self.pageTab(in:)) else { return nil }
        placeholderChecked = true
        defaults.set(true, forKey: Self.placeholderCheckedKey)
        guard let shell = Self.placeholderShell(on: placed.screen, home: NSHomeDirectory()) else { return nil }
        _ = try await connection.closeTabs([shell.surface], endTerminals: true)
        return "home placeholder shell closed"
    }

    /// The one tab right of the Home dock on `screen` when it is a placeholder shell, else nil.
    static func placeholderShell(on screen: ScreenModel, home: String) -> TabModel? {
        let dockPanes = Set(screen.columns.filter { $0.dock != nil }.flatMap(\.layout.paneIDs))
        guard screen.columns.contains(where: { $0.dock?.isPinned == true }) else { return nil }
        let right = screen.panes.filter { !dockPanes.contains($0.handle) }.flatMap(\.tabs)
        guard right.count == 1, let tab = right.first, isPlaceholderShell(tab, home: home) else { return nil }
        return tab
    }

    /// A shell nobody used: a live local terminal at a prompt in the home folder, unnamed, with no
    /// agent, program status, running command, unread mark or keep-layout record, titled by its
    /// folder ("~"). It is what the dock move left on Home's right before `pinned-dock-alone-v1`.
    static func isPlaceholderShell(_ tab: TabModel, home: String) -> Bool {
        guard tab.kind == .pty, !tab.dead, tab.name == nil, tab.agent == nil, tab.agentSession == nil,
              tab.commandSinceMs == nil, tab.programStatus.isEmpty, tab.relaunch == nil, tab.remote == nil,
              !tab.showsUnread, !tab.pinned, tab.tabGroup == nil else { return false }
        let folder = home.hasSuffix("/") ? String(home.dropLast()) : home
        // A shell whose folder is unknown is not known to be the placeholder.
        let atHome = tab.cwd.map { $0 == folder || $0 == folder + "/" } ?? false
        let title = tab.title.trimmingCharacters(in: .whitespaces)
        return atHome && (title.isEmpty || title == "~" || title == folder)
    }

    /// The left chat dock column holding `pane` on `screen`, if any.
    static func dockColumn(_ pane: PaneModel, on screen: ScreenModel) -> ColumnSnapshot? {
        screen.columns.first { column in
            column.dock?.edge == .left && column.dock?.role == .agentChat && column.layout.paneIDs.contains(pane.handle)
        }
    }

    /// A Chief conversation tab: a conversation tab whose source is a conversation (not a page or
    /// an agent session). In the home workspace only Home makes them (`new-conversation-tab`).
    public static func isChiefTab(_ tab: TabModel) -> Bool {
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

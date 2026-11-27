import CmuxNextCompat
public import CmuxNextDaemon
public import CmuxNextDesign
public import CmuxNextHome
public import CmuxNextHomeModel
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
    /// Classic Home: the top page, with the Chief tab in the hidden home workspace. Only
    /// `CMUX_NEXT_CLASSIC_HOME=1` at launch selects it (the GUI checks of the native Home,
    /// scripts/cmux-next/home_classic.py); its Labs setting `labs.classicHome` is retired. Read once
    /// at launch, so Home is never half docked (the dock ensure runs only on connects; a live flip
    /// would leave the old form's tabs and refuse Home's actions).
    public static var classic: Bool { classicAtLaunch }
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
    /// The allow-tabs step waiting for the dock's resource ids (``allowTabsWhenIdentified``); read by tests.
    private(set) var allowTabsWait: Task<Void, Never>?
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

    /// Home's page tab is in its dock, where it stays (`dock.page_is_docked`).
    public static func pageIsDocked(in home: WorkspaceModel) -> Bool {
        dockRule("dock.page_is_docked", HomeRequest(home), fallback: false)
    }

    /// Home shows from its saved state (launch-shell-first.md, piece 3): once `home`'s page is
    /// mounted in its dock (called after an on-screen workspace's apply), `.home` is ready. The page
    /// draws its list and last Chief from the Home cache, or its empty first frame on a first
    /// install, and the Chief owner fills it in under it: the reveal never waits for the owner's
    /// first page or the deadline. Classic Home keeps its first-page path. True when it marked.
    /// `dock.reveal_when_docked`; the cheap checks first, since it runs after every apply.
    @MainActor public static func revealWhenDocked(_ home: WorkspaceModel, reveal: LaunchReveal) -> Bool {
        guard home.kind == "home", !reveal.isReady(.home) else { return false }
        var request = HomeRequest(home)
        request.classic = classic
        guard dockRule("dock.reveal_when_docked", request, fallback: false) else { return false }
        reveal.markReady(.home)
        return true
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
        // The Chief and legacy dock tabs to close, whether the page is docked, and what the move leaves (`dock.ensure_plan`).
        let plan = dockRule("dock.ensure_plan", HomeRequest(workspace(), store: store), fallback: EnsurePlan(step: "gone"))
        guard plan.step == "place" else { return "page tab not shown" }
        let closeTabs = plan.closeTabs ?? [], alone = plan.alone ?? false
        if !closeTabs.isEmpty { try await connection.closeTabs(closeTabs.map(SurfaceID.init(rawValue:)), endTerminals: false) }
        if plan.docked == true {
            let pinned = try await pin(connection, store: store, workspace: workspace)
            let tabs = await allowTabsLogged(connection, store: store, workspace: workspace, fresh: pinned != nil)
            let cleared = alone ? try await closePlaceholder(connection, workspace: workspace) : nil
            let steps = [pinned, tabs, cleared].compactMap { $0 }
            return steps.isEmpty ? "home dock present" : steps.joined(separator: ", ")
        }
        let respawn: SplitRespawn? = plan.respawnTerminal == true ? .terminal(SpawnOptions(workspace: workspace()?.key)) : nil
        moveInFlight = true
        defer { moveInFlight = false }
        let moved = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            dock(placed.tab, placed.pane, respawn, alone) { done.resume(returning: $0) }
        }
        guard moved else { return "home dock move failed (see the app log)" }
        // Held until the tree shows the dock (or this run is cancelled), so a connect meanwhile reads it.
        _ = await shown { workspace().flatMap { Self.pageIsDocked(in: $0) ? true : nil } }
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
        let home = workspace()
        guard let plan = dockRule("dock.pin_plan", HomeRequest(home, store: store), fallback: PinPlan?.none),
              // The dock as the tree has it (its mode too), sent back pinned.
              let dock = home?.screens.lazy.flatMap(\.columns).first(where: { $0.layout.paneIDs.contains { $0.rawValue == plan.pane } })?.dock
        else { return nil }
        let pane = PaneID(rawValue: plan.pane)
        if plan.moveFirst {
            // The pinned tab is the column's first tab: the page goes first before the pin.
            _ = try await connection.moveTab(SurfaceID(rawValue: plan.surface), to: pane, index: 0)
        }
        _ = try await connection.request(SetColumnDockRequest(pane: pane, dock: dock, pinned: true))
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
                                 workspace: @escaping @MainActor @Sendable () -> WorkspaceModel?, fresh: Bool) async -> String? {
        await allowTabsLogged(store: store, workspace: workspace, fresh: fresh) { screen, pane in
            try await connection.setColumnAllowsTabs(true, screen: screen, pane: pane)
        }
    }

    /// The `column.update {allow_tabs: true}` of the dock column on `screen` holding `pane` (tests pass their own).
    typealias AllowTabs = @Sendable (_ screen: ResourceID, _ pane: ResourceID) async throws -> Void

    /// ``allowTabsLogged(_:store:workspace:fresh:)`` with the request as `allow`.
    func allowTabsLogged(store: DaemonStore, workspace: @escaping @MainActor @Sendable () -> WorkspaceModel?, fresh: Bool,
                         allow: @escaping AllowTabs) async -> String? {
        do {
            return try await allowTabs(store: store, workspace: workspace, fresh: fresh, allow: allow)
        } catch {
            logger.error("home dock allow_tabs: \(String(describing: error), privacy: .public)")
            return "home dock allow_tabs failed: \(String(describing: error))"
        }
    }

    private func allowTabs(store: DaemonStore, workspace: @escaping @MainActor @Sendable () -> WorkspaceModel?, fresh: Bool,
                           allow: @escaping AllowTabs) async throws -> String? {
        // This step (a connect's, or the wait's own) supersedes a wait for the ids.
        allowTabsWait?.cancel()
        allowTabsWait = nil
        var request = HomeRequest(workspace(), store: store)
        request.fresh = fresh
        request.dockTakesTabs = defaults.bool(forKey: Self.dockTakesTabsKey)
        let plan = dockRule("dock.allow_tabs_plan", request, fallback: AllowTabsPlan(action: "none"))
        switch plan.action {
        case "record":
            // A dock just pinned may not show its pin in the tree yet; the daemon has it (the pin replied).
            defaults.set(true, forKey: Self.dockTakesTabsKey)
            return nil
        case "waitForIds":
            // The step runs again when the tree first reports the ids (FC-1: it waited for the next connect, and the
            // dock took no tab for the whole launch). Event-driven: the store's records, no timer.
            allowTabsWhenIdentified(store: store, workspace: workspace, fresh: fresh, allow: allow)
            return "home dock allow_tabs waits for resource ids"
        case "allow":
            guard let screen = plan.screen, let pane = plan.pane else { return nil }
            try await allow(ResourceID(rawValue: screen), ResourceID(rawValue: pane))
            defaults.set(true, forKey: Self.dockTakesTabsKey)
            return "home dock takes tabs"
        default:
            return nil
        }
    }

    /// Runs the allow-tabs step again once Home's page is in a dock whose screen and pane have their resource ids, or
    /// stops when the page is gone. One wait at a time: a later step (a connect) replaces it.
    private func allowTabsWhenIdentified(store: DaemonStore, workspace: @escaping @MainActor @Sendable () -> WorkspaceModel?,
                                         fresh: Bool, allow: @escaping AllowTabs) {
        allowTabsWait?.cancel()
        // task-owner: `allowTabsWait`, replaced by the next step and ended when the ids come or the page goes;
        // event-driven (Observation of the store's records), no timer.
        allowTabsWait = Task { [weak self] in
            let identified: @MainActor @Sendable () -> Bool? = {
                dockRule("dock.ids_ready", HomeRequest(workspace()), fallback: Bool?.some(false))
            }
            // `self?.shown` holds this HomeDock across the await on purpose: a window Home makes a HomeDock per connect
            // (`WindowHomes.ensureDock`) and keeps none, so the wait is what keeps it until the ids come or the page goes.
            guard await self?.shown(identified) == true, !Task.isCancelled, let self else { return }
            allowTabsWait = nil // the step below must not cancel the task it runs in
            let step = await allowTabsLogged(store: store, workspace: workspace, fresh: fresh, allow: allow)
            logger.notice("home dock allow_tabs once identified: \(step ?? "nothing to do", privacy: .public)")
        }
    }

    /// A home restored from before `pinned-dock-alone-v1` kept the terminal the dock move left on
    /// its right. A one-time migration: the first time a launch sees the docked Home, when that
    /// column holds nothing but such a shell (``isPlaceholderShell``), it closes and the dock stands
    /// alone; a column with anything real in it is kept as it was. Never again after that check.
    func closePlaceholder(_ connection: DaemonConnection,
                          workspace: @MainActor @Sendable () -> WorkspaceModel?) async throws -> String? {
        var request = HomeRequest(workspace())
        request.checked = placeholderChecked
        request.checkedEver = defaults.bool(forKey: Self.placeholderCheckedKey)
        request.home = NSHomeDirectory()
        let plan = dockRule("dock.placeholder_plan", request, fallback: PlaceholderPlan(markChecked: false, close: nil))
        guard plan.markChecked else { return nil }
        placeholderChecked = true
        defaults.set(true, forKey: Self.placeholderCheckedKey)
        guard let shell = plan.close else { return nil }
        _ = try await connection.closeTabs([SurfaceID(rawValue: shell)], endTerminals: true)
        return "home placeholder shell closed"
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
        guard dockRule("dock.opens_link", ["scheme": url.scheme], fallback: false) else { return }
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

    /// The request of the `dock.*` Home ops: the home's tree and the flags each plan reads.
    nonisolated struct HomeRequest: Encodable {
        nonisolated struct Capabilities: Encodable {
            var pinnedDock = false
            var pinnedDockAlone = false
        }

        var workspace: DockWorkspace?
        var capabilities = Capabilities()
        var fresh = false
        var dockTakesTabs = false
        var checked = false
        var checkedEver = false
        var home = ""
        var classic = false
        var ready = false
    }

    private nonisolated struct EnsurePlan: Decodable {
        var step: String
        var closeTabs: [UInt64]?
        var docked: Bool?
        var alone: Bool?
        var respawnTerminal: Bool?
    }

    private nonisolated struct PinPlan: Decodable {
        var moveFirst: Bool
        var surface: UInt64
        var pane: UInt64
    }

    private nonisolated struct AllowTabsPlan: Decodable {
        var action: String
        var screen: String?
        var pane: String?
    }

    private nonisolated struct PlaceholderPlan: Decodable {
        var markChecked: Bool
        var close: UInt64?
    }
}

extension HomeDock.HomeRequest {
    /// The request for `home` (none: the workspace is gone), with the daemon's dock capabilities when `store` is given.
    @MainActor init(_ home: WorkspaceModel?, store: DaemonStore? = nil) {
        workspace = home.map(DockWorkspace.init)
        if let store {
            capabilities = Capabilities(pinnedDock: store.supports(DaemonCapability.pinnedDock.rawValue),
                                        pinnedDockAlone: store.supports(DaemonCapability.pinnedDockAlone.rawValue))
        }
    }
}

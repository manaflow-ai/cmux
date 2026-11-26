import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextLaunchImages
import CmuxNextLayout
import CmuxNextSidebar
import CmuxNextControl
import CmuxNextWakeups

/// Pending window record saves: at most one in flight and one after it, in order.
struct WindowRecordSaves {
    var requested = false
    var scheduled = false
    var inFlight = false
    /// Tickets of the actions the next write carries; they close once it lands, so `action.run`
    /// answers after the record is stored (plans/cmux-next/state-ownership.md 3 and 4).
    var tickets: [CommandTicket] = []
    /// The task draining saves, so the quit flush can await it.
    var drain: Task<Void, Never>?
}

/// Writes the window records in the daemon's `personal` projection (state-ownership.md 3): tab per
/// pane and focused pane, on each selection or focus change, coalesced per turn (`WindowRecordSaves`);
/// an unchanged document writes nothing. Geometry settles for 500 ms first. Owned by `WindowManager`.
@MainActor
final class WindowRecordSaver {
    weak var owner: WindowManager?
    weak var host: AppServices?
    private let work: BackgroundWork
    /// Debounced save of window geometry (architecture.md 1: 500 ms).
    let geometryTimer = DemandTimer(owner: "WindowManager.geometry")
    /// The focused pane's save waits for the commit that shows the move (``focusDidSettle(_:pane:)``).
    private var afterCommit: CommitProbe?
    /// A focused-pane save waits for that commit, or for ``afterCommitDeadline``.
    private var awaitingCommit = false
    /// Tickets of the focus moves that wait for that commit: they join the save that follows it
    /// (not a write already in flight, which does not carry their pane).
    private var focusTickets: [CommandTicket] = []
    /// The deadline of a focused-pane save whose window shows no commit (occluded, unlit).
    private let afterCommitTimer = DemandTimer(owner: "WindowRecordSaver.afterCommit")
    static let afterCommitDeadline: Duration = .milliseconds(100)
    /// Coalesced saves of the window records.
    var saves = WindowRecordSaves()
    /// The daemon's window records of this install (`window-records-v1`).
    private let recordMirror = WindowRecordMirror()
    private(set) lazy var launchRecord = AppLaunchRecord(
        bundleID: host?.environment.launch.bundleID,
        work: work,
        restored: { [weak self] in self?.host?.windows.restored ?? false },
        socketPath: { [weak self] in await self?.host?.launchRecordSocketPath },
        snapshot: { [weak self] images, socketPath in
            self?.host?.launchRecordSnapshot(images: images, socketPath: socketPath) ?? LaunchRecordSnapshot()
        })
    private(set) lazy var launchImages = WindowLaunchImages(windows: { [weak self] in self?.owner?.launchImageWindows ?? [] }, // stage 0's frames
        isTerminating: { [weak self] in self?.owner?.isTerminating ?? true }, work: work,
        image: { [weak self] window in guard let services = self?.host else { return nil }; return try? await AppWindowImage(services: services).capture(window, overlays: false) }, record: launchRecord, bundleID: host?.environment.launch.bundleID)
    /// Every window's layout, for the next launch to draw already placed.
    private(set) lazy var layoutCache = LayoutCacheWriter(bundleID: host?.environment.launch.bundleID, work: work,
        restored: { [weak self] in self?.host?.windows.restored ?? false }, snapshot: { [weak self] in self?.host?.layoutCacheJSON() })
    private var selectedTabsCache: [String: TabSelectionRecord] = [:]
    /// Kept until the window's list changes (`WindowListMemberships`); the launch record's rows until a row changes.
    private(set) var memberships = WindowListMemberships<WorkspaceKey>()
    let launchRows = SidebarRowsCache<LaunchRecordSidebarSnapshot>()
    /// Panes whose remembered tab a record build read on the main thread (`SpaceSwitchRecordSaveTests`).
    var paneReads: Int { selectedTabsCache.values.reduce(0) { $0 + $1.paneReads } }
    private var services: AppServices? { host }

    init(manager: WindowManager) {
        owner = manager
        host = manager.services
        work = manager.services.work
    }

    /// A selection, focus, membership or sidebar change: save on the next turn.
    func stateDidChange(_ state: WindowState) {
        guard let manager = owner else { return }
        guard manager.restored, !manager.isTerminating else { return }
        layoutCache.note()
        requestSave()
    }

    /// A frame change: save once it has settled for 500 ms.
    func geometryDidChange(_ state: WindowState) {
        guard let manager = owner else { return }
        guard manager.restored, !manager.isTerminating else { return }
        layoutCache.note()
        geometryTimer.schedule(after: .milliseconds(500)) { @MainActor [weak self] in self?.requestSave() }
    }

    func scheduleSave() {
        guard let manager = owner else { return }
        guard let any = manager.states.values.first else { return }
        stateDidChange(any)
    }

    /// Records the window's focused pane when it changed (the focus coordinator settled), and saves.
    func focusDidSettle(_ state: WindowState, pane: String?) {
        guard let manager = owner else { return }
        guard state.savedFocusedPane != pane else { return }
        state.savedFocusedPane = pane
        guard manager.restored, !manager.isTerminating else { return }
        // The move's frame first (speed-of-sound-DESIGN.md 3.2): the save builds every window's
        // records on the main actor, so it starts once the commit that shows the move ran. The
        // ticket opens now, so the action that moved focus still answers once the record is stored.
        guard let host = manager.controller(for: state.id)?.window?.contentView?.layer else { return requestSave() }
        if let ticket = services?.daemon.openTicket() { focusTickets.append(ticket) }
        guard !awaitingCommit else { return }
        awaitingCommit = true
        let probe = afterCommit ?? CommitProbe { [weak self] _, _ in self?.commitShowedFocus() }
        afterCommit = probe
        probe.mark(in: host)
        // Bounded, cancellable deadline (DemandTimer): a window that commits nothing still saves.
        afterCommitTimer.schedule(after: Self.afterCommitDeadline) { @MainActor [weak self] in self?.commitShowedFocus() }
    }

    /// The commit that shows a focus move ran (or its deadline passed): the save it waited for starts.
    private func commitShowedFocus() {
        guard awaitingCommit else { return }
        awaitingCommit = false
        afterCommitTimer.cancel()
        afterCommit?.remove()
        saves.requested = true
        saves.tickets += focusTickets
        focusTickets = []
        scheduleDrain()
    }

    private func requestSave() {
        launchRecord.schedule(); launchImages.windowsChanged()
        saves.requested = true
        if let ticket = services?.daemon.openTicket() { saves.tickets.append(ticket) }
        scheduleDrain()
    }

    private func scheduleDrain() {
        guard saves.requested, !saves.inFlight, !saves.scheduled else { return }
        saves.scheduled = true
        // Not part of any action's scope: a projection write keeps a fresh
        // mutation id (its CAS retries must not replay an earlier write).
        DaemonCommandScope.$current.withValueInTask(nil) {
            // task-owner: one coalesced save per main-actor turn; drainSaves ends when no save is requested
            saves.drain = Task { @MainActor [weak self] in await self?.drainSaves() }
        }
    }

    /// Writes the records once more after any write in flight, so an older one cannot land after it (quit).
    func flushSaves() async {
        commitShowedFocus()
        requestSave()
        await saves.drain?.value
    }

    private func drainSaves() async {
        saves.scheduled = false
        guard !saves.inFlight else { return }
        guard let services else { saves.requested = false; return }
        saves.inFlight = true
        // wakeup-allow: each iteration writes one requested save; ends when none is pending
        while saves.requested, let manager = owner, !manager.isTerminating {
            saves.requested = false
            let tickets = saves.tickets
            saves.tickets = []
            let requested = CACurrentMediaTime()
            let failure = await saveNow()
            if failure == nil { DebugTabSwitch.confirmed(requestedAt: requested) }
            for ticket in tickets { await services.daemon.closeTicket(ticket, label: "save window records", error: failure) }
        }
        saves.inFlight = false
        let leftover = saves.tickets
        saves.tickets = []
        for ticket in leftover { await services.daemon.closeTicket(ticket, label: "save window records", error: nil) }
    }

    /// Writes the records; returns why they were not stored, or nil. Nothing is written while the
    /// stored records are unread (`WindowManager.savedWindowsUnread`): they would be replaced by this
    /// launch's windows alone, and the next launch would lose the others (#26681). That skip answers
    /// nil: the action that asked for the save did its work, only its record is not kept.
    @discardableResult
    func saveNow() async -> (any Error)? {
        guard let manager = owner else { return nil }
        guard !manager.savedWindowsUnread else { return nil }
        guard let services, let windowState = services.daemon.windowState else { return DaemonError.notConnected }
        DebugPaneFocus.noteMainWork("record_saves")
        manager.captureGeometry()
        let records = currentRecords()
        // The front open window's place, kept once its record is pruned (`WindowStateDocument.lastFrame`).
        let front = records.filter { !$0.isClosed && $0.frame != nil }.min { $0.order < $1.order }
        // Keys on a machine, plus own ones whose machine has not loaded yet: only those the records name (`liveKeys`).
        let live = WindowStateDocument.liveKeys(of: records, kept: { !manager.isDead($0.rawValue) },
                                                onMachine: { services.machines.workspace(id: $0.rawValue)?.0.key == $0 })
        do {
            try await windowState.update { document in
                document.windows = records
                document.prune(liveWorkspaces: live)
                if let front {
                    document.lastFrame = front.frame
                    document.lastDisplay = front.display
                }
            }
            await mirror(records)
            return nil
        } catch {
            services.daemon.logger.error("window state save failed: \(String(describing: error), privacy: .public)")
            return error
        }
    }

    /// Mirrors the windows into the daemon's window records (`WindowRecordMirror`).
    private func mirror(_ records: [WindowRecord]) async {
        guard let services else { return }
        let daemon = services.daemon
        guard daemon.supports(DaemonCapability.windowRecords.rawValue), let connection = daemon.connection,
              let install = try? await services.cloud.installID() else { return }
        await recordMirror.sync(records, installID: install, client: connection.state) { message in
            daemon.logger.error("\(message, privacy: .public)")
        }
    }

    /// Front first by the registry's recency (`WindowManager.windowDidOrder`): a save never asks the
    /// window server (`NSApp.orderedWindows` is a synchronous query, cx-8w027.25).
    func currentRecords() -> [WindowRecord] {
        guard let manager = owner else { return [] }
        let value = manager.registry.value
        let states = manager.states
        let order = Dictionary(value.recency.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        memberships.keep { value.window($0) != nil }
        return value.windows.compactMap { window in
            let members = memberships.of(window, machines: manager.seenMachine, localID: MachineRegistry.localID, key: WorkspaceKey.init(rawValue:)), controller = manager.controller(for: window.id)
            var record = value.record(window.id, state: states[window.id], order: order[window.id] ?? order.count,
                                      isFullScreen: (controller?.window?.styleMask.contains(.fullScreen) == true
                                          // full screen only for a page's fullscreen is not the window's own
                                          && controller?.pagePresentation?.entersWindowFullScreen != true)
                                          || states[window.id]?.restoresFullScreen == true,
                                      selectedTabs: selectedTabs(window: window, in: value, listed: members.listed),
                                      machines: manager.seenMachine, membership: members)
            record?.focusedPane = states[window.id].flatMap { $0.focus.state.pane ?? $0.savedFocusedPane }
            record?.focusedPanes = focusedPanes(window: window, listed: members.listed)
            return record
        }
    }

    /// The pane last focused in each workspace the window lists (focus memory, the shown one's pane).
    private func focusedPanes(window: WindowRegistry.Window, listed: Set<String>) -> [String: String] {
        guard let manager = owner else { return [:] }
        guard let state = manager.states[window.id] else { return [:] }
        let focus = state.focus.state
        var panes = state.focus.rememberedPanes()
        if let workspace = focus.topology.workspace, let pane = focus.pane { panes[workspace] = pane }
        return panes.filter { listed.contains($0.key) }
    }

    /// Remembered tab per pane across the window's workspaces, kept between saves (`TabSelectionRecord`): a save
    /// after a switch reads no pane.
    private func selectedTabs(window: WindowRegistry.Window, in registry: WindowRegistry, listed: Set<String>) -> [String: String] {
        guard let manager = owner else { return [:] }
        guard let services else { return [:] }
        guard let memory = manager.states[window.id]?.selection else { return [:] }
        return selectedTabsCache[window.id, default: TabSelectionRecord()].tabs(
            of: memory, workspaces: window.workspaceIDs, stores: services.machines.daemons.map(\.store),
            workspace: { services.workspace(id: $0) },
            // The registry names the first window that lists a workspace: this one's list only for another's.
            lists: { registry.owner(of: $0) == window.id || listed.contains($0) })
    }
}

@MainActor
extension AppServices {
    var launchRecordSocketPath: String? {
        get async { await daemon.connection?.endpoint?.socketPath }
    }

    func launchRecordSnapshot(images: [String: LaunchRecordImage], socketPath: String) -> LaunchRecordSnapshot {
        let manager = windows
        let front = manager.active
        let controllers = manager.controllers.filter { !manager.isIncognito(window: $0.state.id) }
        let ordered = controllers.filter { $0 === front } + controllers.filter { $0 !== front }
        let shown = Set(ordered.flatMap { $0.mountedContents.filter { !$0.isParked }.map { $0.workspace.id } })
        let sidebars = manager.recordSaver.launchRows.rows(of: ordered.map(\.sidebar.model)) {
            LaunchRecordSidebarSnapshot(id: $0.id, title: $0.title, iconKey: $0.icon ?? "")
        }.filter { !shown.contains($0.id) }
        let windows = ordered.compactMap { controller -> LaunchRecordWindowSnapshot? in
            guard let window = controller.window else { return nil }
            let tabs = controller.mountedContents.filter { !$0.isParked }.flatMap { content in
                content.panes.values.filter { !$0.view.isHiddenOrHasHiddenAncestor }.compactMap { $0.stripModel.selectedID?.rawValue }
            }
            return WindowLaunchImages.snapshot(id: controller.state.id, window: window, background: controller.themeScope.tokens.surfaceBackground,
                image: images[controller.state.id], workspaceID: controller.state.workspaceID ?? "", tabIDs: tabs)
        }
        return LaunchRecordSnapshot(windows: windows, sidebarRows: sidebars, sessionSocketPath: socketPath)
    }

    /// The layout cache's JSON for every window but incognito ones, front first (LayoutCacheWriter), from values
    /// already computed. TODO: each pane's kind, scroll, terminal grid and chat anchor; the sidebar's scroll; pictures.
    func layoutCacheJSON() -> String? {
        let manager = windows, front = manager.active
        let controllers = manager.controllers.filter { !manager.isIncognito(window: $0.state.id) }
        let layouts = (controllers.filter { $0 === front } + controllers.filter { $0 !== front }).compactMap { controller -> LayoutCacheWindow? in
            guard let window = controller.window else { return nil }
            let color = controller.themeScope.tokens.surfaceBackground, content = controller.content
            let panes = content?.layoutModel.layoutCacheNode { id in
                content?.panes[id].flatMap { LayoutCacheWindow.contentFrame(of: $0.view, in: window) }
            }
            return .gather(window, id: controller.state.id, surface: [color.red, color.green, color.blue, color.alpha],
                           sidebarWidth: controller.state.sidebarWidth ?? Double(controller.sidebar.model.width),
                           sidebarCollapsed: controller.sidebar.model.isHidden, workspaceId: controller.state.workspaceID ?? "", panes: panes)
        }
        return LayoutCacheDocument.json(layouts)
    }
}

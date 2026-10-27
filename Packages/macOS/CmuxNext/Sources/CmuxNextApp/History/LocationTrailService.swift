import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextHistory
import CmuxNextSettings
import Foundation
import Observation
import CmuxNextFocus

/// The app's side of the location trail (plans/cmux-next/history.md 4.2):
/// records each window's settled focus and runs Go Back / Go Forward / Go to
/// Last Location. The daemon owns the trail (cx-hnmbt.12): each step goes to
/// it with `history.trail.record` (incognito steps never leave memory), and
/// the steps are read back from it at connect. Only the Back/Forward cursor
/// is this app's own view state.
final class LocationTrailService {
    unowned let services: AppServices
    private(set) var trail = LocationTrail()
    private var loaded = false
    private var loading = false
    private var rereads = 0
    /// What the app last read of the daemon's trail, and its steps the daemon never got.
    private var sync = HistoryTrailSync()
    /// The trail's failure log (cx-hnmbt.14): each skipped settle, step, report and reply.
    let log = HistoryTrailLog()
    private var observation: Task<Void, Never>?
    /// Steps go to the daemon in order: one FIFO, so a step never overtakes the one before it.
    private let reports: AsyncStream<@Sendable () async -> Void>.Continuation
    private let reportDrain: Task<Void, Never>
    /// Replaces the clock (tests).
    var now: () -> Date = Date.init
    /// Called after every trail change (the history page, the palette).
    var onChange: (() -> Void)?
    /// More listeners (each window's titlebar Back / Forward buttons): token to handler.
    private var observers: [Int: () -> Void] = [:]
    private var nextObserver = 0

    /// Adds a listener for every trail change (also scope changes: re-read `canNavigate`); returns
    /// the token for ``removeObserver(_:)``.
    @discardableResult
    func addObserver(_ handler: @escaping () -> Void) -> Int {
        nextObserver += 1
        observers[nextObserver] = handler
        return nextObserver
    }

    func removeObserver(_ token: Int) {
        observers[token] = nil
    }

    private func notify() {
        onChange?()
        for handler in observers.values { handler() }
    }

    init(services: AppServices) {
        self.services = services
        let (stream, continuation) = AsyncStream<@Sendable () async -> Void>.makeStream(bufferingPolicy: .bufferingNewest(1_024))
        reports = continuation
        // task-owner: the service's lifetime; ends when the stream finishes in deinit
        reportDrain = Task.detached {
            for await report in stream { await report() }
        }
        // Page views' mouse buttons and swipes run Go Back / Go Forward (history.md 4.2b).
        services.pages.navigate = { [weak services] back in
            _ = services?.registry.perform(back ? "focusHistoryBack" : "focusHistoryForward", invocation: ActionInvocation(origin: .user))
        }
        let store = services.daemon.store
        // Another client changed the daemon's trail (the React History page): read it again.
        store.sideEvents.subscribe { [weak self] event in
            if case .historyChanged(_, let kinds) = event, kinds.contains("location") { self?.reread() }
        }
        observation = Task { [weak self] in
            for await connected in ObservationStream({ if case .connected = store.connectionState { true } else { false } }) where connected {
                self?.loadOnce()
            }
        }
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // Each handle here is Sendable and stops from any thread: a release off main cleans up too.
    nonisolated deinit {
        reports.finish()
        observation?.cancel()
        scopeObservation?.cancel()
    }

    private var scopeObservation: Task<Void, Never>?

    /// Tells the observers when `navigation.historyScope` changes, so the titlebar buttons re-read
    /// ``canNavigate(_:)`` with no trail change. Event driven (observation of the settings snapshot).
    func watchScope(settings: SettingsController) {
        scopeObservation?.cancel()
        scopeObservation = Task { [weak self] in
            var last: String?
            for await scope in ObservationStream({ settings.snapshot.navigationHistoryScope }) {
                defer { last = scope }
                guard let last, last != scope else { continue }
                self?.notify()
            }
        }
    }

    // MARK: Recording

    /// A window's focus settled. Only the active window records (the key
    /// window, else the last active one), so a background CLI change does
    /// not move the trail.
    func focusDidSettle(_ state: FocusState, in controller: WindowController) {
        // Under a top page the workspace's focus is not where the user is.
        guard services.windows.active === controller, controller.shownTopPage == nil else {
            return log.skipped(controller.shownTopPage == nil ? "inactive window" : "top page shown", window: controller.state.id,
                               workspace: state.topology.workspace)
        }
        // The window selected another workspace whose panes have not reached
        // the focus coordinator yet: this settle still describes the
        // workspace it left. Not a place the user went; recording it cut off
        // the forward entries of a Back or Forward between workspaces.
        if let shown = controller.state.workspaceID, state.topology.workspace != shown {
            return log.skipped("settle of workspace left (shown \(shown))", window: controller.state.id, workspace: state.topology.workspace)
        }
        guard let location = location(of: state, in: controller) else {
            log.skipped("no location (target \(state.target), pane \(state.pane ?? "-"))", window: controller.state.id,
                        workspace: state.topology.workspace)
            // The shown page may have changed (another tab): the arrows re-read it.
            pageHistoryDidChange()
            return
        }
        let recorded: Bool
        let time = now(), scope = stepScope
        if let jump = jumpNotedAt, time.timeIntervalSince(jump) < Self.jumpWindow, location.key != trail.current?.location.key {
            jumpNotedAt = nil
            recorded = step(location, at: time, jump: true) { $0.recordJump(location, at: time) }
        } else {
            recorded = step(location, at: time, steps: scope) { $0.record(location, at: time, scope: scope) }
        }
        if recorded { notify() } else { pageHistoryDidChange() }
    }

    /// When the user last picked a jump (``noteJump()``).
    private var jumpNotedAt: Date?
    /// How long a noted jump waits for the focus it causes to settle.
    private static let jumpWindow: TimeInterval = 2

    /// The user picked a place to jump to (the New Tab page's location bar):
    /// the next settled location elsewhere is its own step, even in the same
    /// workspace, so Back returns to where they jumped from.
    func noteJump() {
        jumpNotedAt = now()
    }

    /// What a step is (`navigation.history.scope`, BACK-FORWARD-WORKSPACES-ONLY).
    var stepScope: HistoryStepScope {
        services.settings.flatMap { HistoryStepScope(rawValue: $0.snapshot.navigationHistorySteps) } ?? .default
    }

    /// The user showed top page `route` in the active window: a trail entry
    /// (TOP-SECTION-ITEMS-ARE-PAGES Q2), through the same settle rules.
    /// `origin` is where the window was (`WindowController.trailOrigin`): when the trail's
    /// current entry is not it (a fresh launch, a restored page), it is
    /// recorded first so Go Back leaves the page (`+PageOrigin`).
    func pageDidShow(_ route: TopPageRoute, title: String, origin: HistoryLocation? = nil, in controller: WindowController) {
        guard services.windows.active === controller else { return }
        let location = HistoryLocation.page(route.rawValue, window: controller.state.id, title: title,
                                            isIncognito: services.windows.isIncognito(window: controller.state.id))
        let time = now()
        if let origin, Self.needsOrigin(origin, before: location, current: trail.current?.location) {
            // A jump: neither entry is coalesced away as a quick pass. The origin is a millisecond
            // older, so the daemon's rows (newest first by time) keep the order.
            let before = time.addingTimeInterval(-0.001)
            step(origin, at: before, jump: true) { $0.recordJump(origin, at: before) }
            step(location, at: time, jump: true) { $0.recordJump(location, at: time) }
            notify()
            return
        }
        if step(location, at: time, steps: .everything, { $0.record(location, at: time) }) { notify() }
    }

    // MARK: Navigation

    enum Direction { case back, forward, last }

    /// What Back and Forward walk (`navigation.historyScope`; history.md 4.2a).
    /// With workspace steps (the default) a step is a workspace or top page,
    /// so Back and Forward walk the window's trail; `surface` stays the page's own list.
    var scope: HistoryScope {
        let configured = services.settings.flatMap { HistoryScope(rawValue: $0.snapshot.navigationHistoryScope) } ?? .default
        return stepScope == .workspaces && configured != .surface ? .window : configured
    }

    /// Moves the trail within the scope and focuses the entry. False when there is nowhere to go.
    /// With the `surface` scope the focused surface walks its own list (a browser page's back and
    /// forward); a surface without one does nothing.
    /// The shown page's own history comes first (history.md 4.2b): Back and
    /// Forward walk it, and the trail only past its ends.
    @discardableResult
    func navigate(_ direction: Direction) -> Bool {
        if direction != .last, ActionRunScope.viewChangeAllowed(), let page = pageHistory() {
            if direction == .back ? page.goBack() : page.goForward() { return true }
        }
        let scope = scope
        if scope == .surface {
            switch direction {
            case .back, .last: return services.registry.perform("browserBack")
            case .forward: return services.registry.perform("browserForward")
            }
        }
        let entry: LocationTrail.Entry? = switch direction {
        case .back: trail.back(scope: scope, isAvailable: isAvailable)
        case .forward: trail.forward(scope: scope, isAvailable: isAvailable)
        case .last: trail.last(scope: scope, isAvailable: isAvailable)
        }
        guard let entry else { return false }
        notify()
        if !focus(entry.location) { trail.cancelPending() }
        return true
    }

    /// Whether Back or Forward has somewhere to go now in `controller` (else the active window):
    /// the titlebar buttons' enabled state.
    func canNavigate(_ direction: LocationTrailDirection, in controller: WindowController? = nil) -> Bool {
        if let page = pageHistory(in: controller), direction == .back ? page.canGoBack : page.canGoForward { return true }
        let scope = scope
        guard scope != .surface else { return true }
        return direction == .back ? trail.canGoBack(scope: scope, isAvailable: isAvailable)
            : trail.canGoForward(scope: scope, isAvailable: isAvailable)
    }

    /// The long-press / right-click list of a Back or Forward button, nearest first (the sidebar
    /// lead renders it; each row runs `history.goTo {index}`). Empty with the `surface` scope: the
    /// page's own entry menu is the list there.
    func list(_ direction: LocationTrailDirection) -> [LocationTrailListItem] {
        trail.list(direction, scope: scope, isAvailable: isAvailable)
    }

    /// The headed right-click / long-press list under the Debug Settings layout (history.md 4.2c).
    func menuSections(_ direction: LocationTrailDirection, layout: LocationTrailMenuLayout) -> [LocationTrailMenuSection] {
        trail.menuSections(direction, scope: scope, layout: layout, isAvailable: isAvailable)
    }

    /// Goes to a listed entry (`history.goTo`). False when the index is gone or not focusable.
    @discardableResult
    func go(toIndex index: Int) -> Bool {
        guard trail.entries.indices.contains(index), isAvailable(trail.entries[index].location),
              let entry = trail.go(to: index) else { return false }
        notify()
        if !focus(entry.location) { trail.cancelPending() }
        return true
    }

    // MARK: Page history (history.md 4.2b)

    /// The page history of what `controller` (else the active window) shows: its top page, else
    /// the internal page tab (app-only or store) its focused pane shows.
    func pageHistory(in controller: WindowController? = nil) -> (any PageHistory)? {
        guard let controller = controller ?? services.windows.active else { return nil }
        if let route = controller.shownTopPage {
            guard case .page(let id) = route, let key = controller.topPages.key(for: route) else { return nil }
            return TopPages.provider(id, services: services)?.history(for: key)
        }
        guard case .page(let view)? = controller.focusedPane?.currentContent else { return nil }
        return TopPages.provider(view.page, services: services)?.history(for: view.key)
    }

    /// A page moved through its history, or the shown page changed: the titlebar arrows re-read
    /// ``canNavigate(_:in:)``. The trail itself did not change.
    func pageHistoryDidChange() {
        for handler in observers.values { handler() }
    }

    /// Focuses a trail entry chosen from a list (history page, palette):
    /// recorded like any jump, so Back returns to where the user was.
    @discardableResult
    func goTo(_ location: HistoryLocation) -> Bool {
        focus(location)
    }

    /// Shows the tab: its window comes forward, its workspace and tab are
    /// selected and its pane takes focus.
    private func focus(_ location: HistoryLocation) -> Bool {
        // A run without view-change permission (automation) moves nothing.
        guard ActionRunScope.viewChangeAllowed() else { return false }
        if let page = location.page {
            guard let route = TopPageRoute(rawValue: page) else { return false }
            return TopPages.show(route, services: services, in: services.windows.states[location.window]) != nil
        }
        return services.revealTab(location.key.tab)
    }

    // MARK: Clearing

    func clear(since start: Date?) {
        trail.removeAll { entry in start.map { entry.enteredAt >= $0 } ?? true }
        notify()
    }

    /// Removes every entry of one tab (Remove from History).
    func remove(_ key: HistoryLocation.Key) {
        trail.removeAll { $0.location.key == key }
        notify()
    }

    /// The incognito session ended (its last window closed): its entries go.
    func forgetIncognito() {
        trail.removeAll { $0.location.isIncognito }
        notify()
    }

    // MARK: The daemon's trail

    /// Runs one record on the trail and, when it changed the trail, reports the same step to the
    /// daemon, which runs the same step rules on its trail (cx-hnmbt.12). Incognito steps stay here.
    @discardableResult
    private func step(_ location: HistoryLocation, at time: Date, steps: HistoryStepScope = .workspaces,
                      jump: Bool = false, _ record: (inout LocationTrail) -> Bool) -> Bool {
        let changed = record(&trail)
        log.ruled(location, rule: jump ? "jump" : steps.rawValue, changed: changed)
        guard changed else { return false }
        if !location.isIncognito { report(location, at: time, steps: steps, jump: jump) }
        return true
    }

    private func report(_ location: HistoryLocation, at time: Date, steps: HistoryStepScope, jump: Bool) {
        guard let daemon = services.history.daemonHistory else {
            sync.unsent.insert(HistoryTrailStepID(location.key, time))
            return log.unsent(location)
        }
        let log = log
        log.reported(location, atMs: HistoryTrailStepID(location.key, time).ms, steps: steps.rawValue, jump: jump)
        reports.yield {
            do {
                let reply = try await daemon.recordTrail(window: location.window, location: location, at: time, steps: steps, jump: jump)
                log.replied(location, id: reply.id, recorded: reply.recorded)
            } catch {
                log.failed(location, error)
            }
        }
    }

    /// Reads the daemon's trail once per launch (on the first connection that serves it), and
    /// again when another client changed it (`history-changed` with kind `location`).
    private func loadOnce() {
        guard !loaded, !loading, let daemon = services.history.daemonHistory else { return }
        loading = true
        // task-owner: one read of the daemon's trail; ends with its reply
        Task { [weak self] in
            let steps = try? await daemon.trail()
            guard let self else { return }
            self.loading = false
            guard let steps else { return }
            self.adopt(steps)
        }
    }

    private func adopt(_ steps: [(location: HistoryLocation, time: Date)]) {
        loaded = true
        // Steps taken before the daemon answered stay newest; the ones taken while no daemon served
        // the trail go to it now (the others are in its FIFO already).
        let (merged, resend) = sync.adopt(steps, local: trail)
        log.read("adopted", steps: steps.count, local: trail.entries.count, removed: 0)
        for entry in resend { report(entry.location, at: entry.enteredAt, steps: .everything, jump: true) }
        trail = merged
        notify()
    }

    /// Another client changed the daemon's trail (the React History page): steps that left it
    /// leave Back/Forward too. Only the newest read applies.
    private func reread() {
        guard loaded, let daemon = services.history.daemonHistory else { return }
        rereads += 1
        let generation = rereads
        // task-owner: one read of the daemon's trail; ends with its reply
        Task { [weak self] in
            guard let steps = try? await daemon.trail(), let self, generation == self.rereads else { return }
            let gone = self.sync.reconcile(steps)
            self.log.read("reread", steps: steps.count, local: self.trail.entries.count, removed: gone.count)
            guard !gone.isEmpty else { return }
            self.trail.removeAll { gone.contains(HistoryTrailStepID($0.location.key, $0.enteredAt)) }
            self.notify()
        }
    }
}

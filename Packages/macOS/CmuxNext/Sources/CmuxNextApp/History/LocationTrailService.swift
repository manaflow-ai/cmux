import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextHistory
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Observation

/// Owns the app-wide location trail (plans/cmux-next/history.md 4.2):
/// records each window's settled focus, runs Go Back / Go Forward / Go to
/// Last Location, and keeps the trail in the home session's personal
/// projection `history.trail` (incognito entries never leave memory).
final class LocationTrailService {
    nonisolated static let subject = "history.trail"
    nonisolated static let schemaVersion: UInt32 = 1

    private unowned let services: AppServices
    private(set) var trail = LocationTrail()
    private let saveTimer = DemandTimer(owner: "LocationTrailService.save")
    private var loaded = false
    private var revision: UInt64?
    private var observation: Task<Void, Never>?
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
        let store = services.daemon.store
        observation = Task { [weak self] in
            for await connected in Observations({ if case .connected = store.connectionState { true } else { false } }) where connected {
                self?.loadOnce()
            }
        }
    }

    deinit {
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
            for await scope in Observations({ settings.snapshot.navigationHistoryScope }) {
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
        guard services.windows.active === controller, controller.shownTopPage == nil, let location = location(of: state, in: controller) else { return }
        if trail.record(location, at: now(), scope: stepScope) { changed() }
    }

    /// What a step is (`navigation.history.scope`, BACK-FORWARD-WORKSPACES-ONLY).
    var stepScope: HistoryStepScope {
        services.settings.flatMap { HistoryStepScope(rawValue: $0.snapshot.navigationHistorySteps) } ?? .default
    }

    func location(of state: FocusState, in controller: WindowController) -> HistoryLocation? {
        guard state.target.isPaneScoped || state.target.isSidebar, let pane = state.pane,
              let tabID = state.topology.pane(pane)?.selectedTab?.id,
              let (tab, paneModel) = services.locateTab(tabID) else { return nil }
        let daemon = services.daemon(for: paneModel)
        let workspace = daemon.store.workspace(containing: paneModel.handle)
        let content: HistoryLocation.Content = switch tab.kind {
        case .pty: .terminal
        case .browser: .browser
        default: .other
        }
        let workspaceID = workspace?.id ?? state.topology.workspace ?? ""
        return HistoryLocation(
            key: .init(machine: daemon.machineID, tab: tab.id), window: controller.state.id, workspace: workspaceID,
            pane: paneModel.id, content: content, title: tab.displayTitle.isEmpty ? Strings.untitledTerminal : tab.displayTitle,
            workspaceTitle: workspace?.displayName, machineName: daemon.machineID == MachineRegistry.localID ? nil : daemon.machineID,
            url: tab.url, cwd: tab.cwd, isIncognito: services.windows.isIncognito(workspace: workspaceID))
    }

    /// The user showed top page `route` in the active window: a trail entry
    /// (TOP-SECTION-ITEMS-ARE-PAGES Q2), through the same settle rules.
    func pageDidShow(_ route: TopPageRoute, title: String, in controller: WindowController) {
        guard services.windows.active === controller else { return }
        let location = HistoryLocation.page(route.rawValue, window: controller.state.id, title: title,
                                            isIncognito: services.windows.isIncognito(window: controller.state.id))
        if trail.record(location, at: now()) { changed() }
    }

    // MARK: Navigation

    /// Whether the location's tab exists on a connected machine now.
    func isAvailable(_ location: HistoryLocation) -> Bool {
        if let page = location.page { return TopPageRoute(rawValue: page).map(hasPage) ?? false }
        guard let (_, pane) = services.locateTab(location.key.tab) else { return false }
        return services.daemon(for: pane).machineID == location.key.machine
    }

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
    @discardableResult
    func navigate(_ direction: Direction) -> Bool {
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
        changed()
        if !focus(entry.location) { trail.cancelPending() }
        return true
    }

    /// Whether Back or Forward has somewhere to go now (the titlebar buttons' enabled state).
    func canNavigate(_ direction: LocationTrailDirection) -> Bool {
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

    /// Goes to a listed entry (`history.goTo`). False when the index is gone or not focusable.
    @discardableResult
    func go(toIndex index: Int) -> Bool {
        guard trail.entries.indices.contains(index), isAvailable(trail.entries[index].location),
              let entry = trail.go(to: index) else { return false }
        changed()
        if !focus(entry.location) { trail.cancelPending() }
        return true
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

    private func hasPage(_ route: TopPageRoute) -> Bool {
        if case .page(let id) = route { return TopPages.provider(id, services: services) != nil }
        return true
    }

    // MARK: Clearing

    func clear(since start: Date?) {
        trail.removeAll { entry in start.map { entry.enteredAt >= $0 } ?? true }
        changed()
    }

    /// Removes every entry of one tab (Remove from History).
    func remove(_ key: HistoryLocation.Key) {
        trail.removeAll { $0.location.key == key }
        changed()
    }

    /// The incognito session ended (its last window closed): its entries go.
    func forgetIncognito() {
        trail.removeAll { $0.location.isIncognito }
        changed()
    }

    // MARK: Persistence

    private func changed() {
        notify()
        guard loaded else { return }
        saveTimer.schedule(after: .seconds(1)) { @MainActor [weak self] in self?.save() }
    }

    private func loadOnce() {
        guard !loaded else { return }
        services.daemon.send("history-trail-load") { [weak self] connection in
            let projection = try await connection.frontendProjection(subject: Self.subject)
            let stored: LocationTrail? = projection.schemaVersion == Self.schemaVersion && projection.projection != .null
                ? try? JSONDecoder().decode(LocationTrail.self, from: JSONEncoder().encode(projection.projection)) : nil
            await MainActor.run { self?.adopt(stored, revision: projection.projectionRevision) }
        }
    }

    private func adopt(_ stored: LocationTrail?, revision: UInt64) {
        loaded = true
        self.revision = revision
        // Entries recorded before the load stay newest.
        if var merged = stored {
            for entry in trail.entries { merged.record(entry.location, at: entry.enteredAt) }
            trail = merged
        }
        notify()
    }

    private func save() {
        let snapshot = trail.persistable
        let revision = revision
        services.daemon.send("history-trail-save") { [weak self] connection in
            let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(snapshot))
            // Last writer wins: the trail is this app's own; a conflict
            // (another app instance) retries once without a revision.
            let stored: FrontendProjection
            do {
                stored = try await connection.putFrontendProjection(subject: Self.subject, schemaVersion: Self.schemaVersion,
                                                                    projection: value, expectedRevision: revision)
            } catch DaemonError.command(_, let message, _, _, _) where message.contains("revision conflict") {
                stored = try await connection.putFrontendProjection(subject: Self.subject, schemaVersion: Self.schemaVersion,
                                                                    projection: value)
            }
            await MainActor.run { self?.revision = stored.projectionRevision }
        }
    }
}

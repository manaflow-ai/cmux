public import Foundation

/// Drives the event-driven layout follow-up loop that reconciles terminal and
/// browser portal visibility, terminal geometry, and post-split focus after a
/// split, tab move, zoom toggle, focus change, or portal-rendering change settles.
///
/// Faithful lift of the `Workspace` layout-follow-up subsystem: the follow-up
/// state machine (the pending reason / terminal-focus / browser-panel /
/// browser-exit-focus ids, the needs-geometry flag, the attempt version + stall
/// count, the in-attempt re-entrancy latch), the reparent-focus suppression set,
/// the `portalRenderingEnabled` flag, the convergence/backoff retry loop, and the
/// 2 s timeout. The primitives that walk the live panel registry and portal
/// registries (portal show/hide, geometry reconcile, AppKit focus, the
/// `NotificationCenter` observer install) stay app-side behind
/// ``WorkspaceLayoutFollowUpHosting`` because they hold app-target types; this
/// coordinator never names one.
///
/// **Isolation design.** `@MainActor`, not an actor. Every legacy entry point
/// already ran on the main actor: `beginEventDrivenLayoutFollowUp` is called from
/// SwiftUI `.onChange` and bonsplit delegate callbacks, the retry closures hopped
/// back to `@MainActor`, and the whole loop reads and mutates AppKit view state
/// synchronously within one turn. Co-locating this state with its callers (the
/// rule from stage 3b: state lives where its callers live) turns every bridge into
/// a plain call; an actor here would manufacture an isolation domain the design
/// immediately re-enters. The host is held weakly: `Workspace` owns this
/// coordinator, so a strong back-reference would be a retain cycle.
///
/// **Retry/timeout as Clock tasks, not `DispatchQueue.asyncAfter`.** The legacy
/// loop used `DispatchQueue.main.asyncAfter` for the next attempt (with a 0..0.25 s
/// exponential backoff) and a `DispatchWorkItem` `asyncAfter(2.0)` for the
/// timeout, both banned by `CLAUDE.md`. They become generation-guarded `Task`s
/// that sleep on an injected `any Clock<Duration>` (production passes
/// `ContinuousClock`; tests pass a manual clock). The attempt-version guard makes
/// a stale retry fire a no-op without a `Task.isCancelled` check, exactly as the
/// legacy version check did; the timeout task captures the same version so a
/// refreshed timeout supersedes the old one. `Clock.sleep` is the cancellable,
/// testable replacement for the banned `asyncAfter`.
///
/// **Why async scheduling for the first attempt (preserved).** The legacy code
/// deferred the first attempt via `asyncAfter(0)` because
/// `beginEventDrivenLayoutFollowUp` is often called from inside SwiftUI's active
/// layout pass; running the flush synchronously there re-enters
/// `displayIfNeeded()` and trips AppKit's per-window constraint-pass limit. A
/// `Clock.sleep(for: .zero)` retry task preserves the "always after the current
/// layout pass" deferral.
@MainActor
public final class WorkspaceLayoutFollowUpCoordinator {
    /// Clock backing the retry-backoff and timeout sleeps. Injected so tests
    /// drive cadence deterministically; production uses `ContinuousClock`.
    private let clock: any Clock<Duration>

    /// The follow-up watchdog timeout. Legacy `asyncAfter(deadline: .now() + 2.0)`
    /// on the timeout `DispatchWorkItem`.
    private let timeout: Duration

    /// The app's DEBUG `cmuxDebugLog` sink, carrying the reparent-suppression
    /// trace lines (`focus.reparent.suppressPending` / `.clearPending` /
    /// `.clearReady`) the legacy `#if DEBUG` bodies emitted; the app passes a
    /// no-op in release. Kept app-side so the package never depends on the
    /// DEBUG-only log facility, matching the `WorkspaceCreationCoordinator` wiring.
    private let debugLog: @Sendable (String) -> Void

    private weak var host: (any WorkspaceLayoutFollowUpHosting)?

    /// The observer registration handle, non-nil exactly while a follow-up is
    /// active. Legacy `layoutFollowUpObservers` + `layoutFollowUpPanelsObservation`
    /// (whose combined non-nil state the legacy code tracked via
    /// `layoutFollowUpTimeoutWorkItem != nil`). Its presence is the "follow-up
    /// active" flag the retry/timeout guards key on.
    private var observation: WorkspaceLayoutFollowUpObservation?

    /// The pending timeout task, kept so it can be cancelled and refreshed.
    /// Legacy `layoutFollowUpTimeoutWorkItem`.
    private var timeoutTask: Task<Void, Never>?

    /// The pending retry-attempt task, kept so a fresh begin can supersede it.
    private var attemptTask: Task<Void, Never>?

    private var reason: String?
    private var terminalFocusPanelId: UUID?
    private var browserPanelId: UUID?
    private var browserExitFocusPanelId: UUID?
    private var needsGeometryPass = false
    private var attemptScheduled = false
    private var attemptVersion: Int = 0
    private var stalledAttemptCount = 0
    private var isAttempting = false

    /// Whether portal rendering is enabled for this workspace. Legacy
    /// `Workspace.portalRenderingEnabled`. When false the follow-up loop is inert
    /// and the host hides all portals.
    public private(set) var portalRenderingEnabled = true

    /// The reparent-focus suppression views pending release, keyed by identity.
    /// Legacy `Workspace.pendingReparentFocusSuppressionViews`.
    private var pendingReparentFocusSuppressionViews: [ObjectIdentifier: any WorkspaceReparentSuppressible] = [:]

    /// Creates the coordinator. Call ``attach(host:)`` before use.
    ///
    /// - Parameters:
    ///   - clock: the clock backing the retry and timeout sleeps
    ///     (default `ContinuousClock`).
    ///   - timeout: the follow-up watchdog timeout (default 2 s, the legacy
    ///     `asyncAfter(2.0)`).
    ///   - debugLog: the app's DEBUG `cmuxDebugLog` sink for the
    ///     reparent-suppression trace (default no-op; the app passes its sink in
    ///     DEBUG).
    public init(
        clock: any Clock<Duration> = ContinuousClock(),
        timeout: Duration = .seconds(2),
        debugLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.clock = clock
        self.timeout = timeout
        self.debugLog = debugLog
    }

    /// Wires the app-side host the follow-up loop drives through. Held weakly.
    public func attach(host: any WorkspaceLayoutFollowUpHosting) {
        self.host = host
    }

    // MARK: - Portal rendering

    /// Enables or disables portal rendering for this workspace, beginning a
    /// follow-up on enable (when changed) and clearing + hiding all portals on
    /// disable. Legacy `Workspace.setPortalRenderingEnabled(_:reason:)`.
    public func setPortalRenderingEnabled(_ enabled: Bool, reason: String) {
        let changed = portalRenderingEnabled != enabled
        portalRenderingEnabled = enabled
        if enabled {
            if changed {
                begin(reason: reason, includeGeometry: true)
            }
        } else {
            clear()
            host?.layoutFollowUpHideAllPortals()
        }
    }

    /// Disables portal rendering without the enable-path side effects, for surface
    /// teardown (legacy `Workspace.disablePortalRendering()`).
    public func disablePortalRendering() {
        portalRenderingEnabled = false
    }

    // MARK: - Begin / schedule

    /// Begins (or refreshes) an event-driven layout follow-up. Legacy
    /// `Workspace.beginEventDrivenLayoutFollowUp(reason:browserPanelId:browserExitFocusPanelId:terminalFocusPanelId:includeGeometry:)`.
    public func begin(
        reason: String,
        browserPanelId: UUID? = nil,
        browserExitFocusPanelId: UUID? = nil,
        terminalFocusPanelId: UUID? = nil,
        includeGeometry: Bool = false
    ) {
        guard portalRenderingEnabled else { return }
        self.reason = reason
        if let browserPanelId {
            self.browserPanelId = browserPanelId
        }
        if let browserExitFocusPanelId {
            self.browserExitFocusPanelId = browserExitFocusPanelId
        }
        if let terminalFocusPanelId {
            self.terminalFocusPanelId = terminalFocusPanelId
        }
        needsGeometryPass = needsGeometryPass || includeGeometry
        stalledAttemptCount = 0
        // Invalidate any pending retry whose delay was computed from a stale stall
        // count. Incrementing the version causes old retry tasks to exit early;
        // clearing the flag allows scheduleAttempt() below to enqueue a fresh
        // zero-delay attempt.
        attemptVersion &+= 1
        attemptScheduled = false

        if observation == nil {
            installObservers()
        }
        refreshTimeout()
        // Use async scheduling instead of a synchronous call here. begin() is
        // often invoked from splitTabBar(_:didChangeGeometry:), which fires from
        // inside SwiftUI's .onChange(of: geometry) during an active layout pass.
        // Calling attempt() synchronously in that context causes the window-layout
        // flush -> displayIfNeeded() to be called re-entrantly, incrementing
        // AppKit's per-window constraint-pass counter on every display cycle until
        // it exceeds the limit and crashes with NSGenericException.
        // scheduleAttempt() defers via a zero-delay Clock sleep so the flush always
        // happens after the current layout pass completes.
        scheduleAttempt()
    }

    /// Begins a geometry-only follow-up. Legacy
    /// `Workspace.scheduleTerminalGeometryReconcile()`.
    public func scheduleTerminalGeometryReconcile() {
        begin(reason: "workspace.geometry", includeGeometry: true)
    }

    // MARK: - Reparent-focus suppression

    /// Suppresses a view's reparent-focus side effects until the follow-up
    /// settles, beginning a geometry follow-up. Legacy
    /// `Workspace.suppressReparentFocusUntilLayoutFollowUp(_:reason:)`.
    public func suppressReparentFocus(
        _ hostedView: (any WorkspaceReparentSuppressible)?,
        reason: String
    ) {
        guard let hostedView else { return }
        hostedView.suppressReparentFocus()
        pendingReparentFocusSuppressionViews[ObjectIdentifier(hostedView)] = hostedView
        debugLog("focus.reparent.suppressPending reason=\(reason) count=\(pendingReparentFocusSuppressionViews.count)")

        guard portalRenderingEnabled else {
            clearPendingReparentFocusSuppressions(reason: "\(reason).portalDisabled")
            return
        }

        begin(reason: reason, includeGeometry: true)
    }

    /// Whether any reparent-focus suppression is pending. Legacy
    /// `Workspace.hasActivePendingReparentFocusSuppressions` /
    /// `debugHasPendingReparentFocusSuppressionsForTesting()`.
    public var hasActivePendingReparentFocusSuppressions: Bool {
        !pendingReparentFocusSuppressionViews.isEmpty
    }

    /// Whether the given view is in the pending reparent-focus suppression set.
    /// Replaces the legacy
    /// `pendingReparentFocusSuppressionViews.values.contains { $0 === hostedView }`
    /// scan the focus path performed inline.
    public func hasPendingReparentFocusSuppression(
        for hostedView: any WorkspaceReparentSuppressible
    ) -> Bool {
        pendingReparentFocusSuppressionViews[ObjectIdentifier(hostedView)] != nil
    }

    private func clearPendingReparentFocusSuppressions(reason: String) {
        guard !pendingReparentFocusSuppressionViews.isEmpty else { return }
        let hostedViews = Array(pendingReparentFocusSuppressionViews.values)
        pendingReparentFocusSuppressionViews.removeAll()
        debugLog("focus.reparent.clearPending reason=\(reason) count=\(hostedViews.count)")
        for hostedView in hostedViews {
            hostedView.clearSuppressReparentFocus()
        }
    }

    private func clearReadyPendingReparentFocusSuppressions(reason: String) {
        guard !pendingReparentFocusSuppressionViews.isEmpty else { return }
        let readyKeys = pendingReparentFocusSuppressionViews.compactMap { key, hostedView in
            hostedView.canClearPendingReparentFocusSuppressionAfterLayoutAttempt() ? key : nil
        }
        guard !readyKeys.isEmpty else { return }
        let hostedViews = readyKeys.compactMap { pendingReparentFocusSuppressionViews[$0] }
        for key in readyKeys {
            pendingReparentFocusSuppressionViews.removeValue(forKey: key)
        }
        debugLog("focus.reparent.clearReady reason=\(reason) count=\(hostedViews.count)")
        for hostedView in hostedViews {
            hostedView.clearSuppressReparentFocus()
        }
    }

    // MARK: - Observers / timeout / clear

    private func installObservers() {
        guard observation == nil else { return }
        observation = host?.beginObservingLayoutFollowUpEvents { [weak self] in
            self?.scheduleAttempt()
        }
    }

    private func refreshTimeout() {
        timeoutTask?.cancel()
        let scheduledVersion = attemptVersion
        timeoutTask = Task { [weak self, clock, timeout] in
            try? await clock.sleep(for: timeout)
            guard let self, self.attemptVersion == scheduledVersion else { return }
            self.clear()
        }
    }

    /// Ends the active follow-up: clears pending suppressions, the observers, the
    /// timeout, and all follow-up state. Legacy `Workspace.clearLayoutFollowUp()`.
    public func clear() {
        clearPendingReparentFocusSuppressions(reason: "workspace.layoutFollowUpEnd")
        timeoutTask?.cancel()
        timeoutTask = nil
        attemptTask?.cancel()
        attemptTask = nil
        observation?.cancel()
        observation = nil
        reason = nil
        terminalFocusPanelId = nil
        browserPanelId = nil
        browserExitFocusPanelId = nil
        needsGeometryPass = false
        attemptVersion &+= 1
        attemptScheduled = false
        stalledAttemptCount = 0
    }

    private func scheduleAttempt() {
        guard portalRenderingEnabled else { return }
        guard observation != nil else { return }
        guard !attemptScheduled else { return }

        attemptScheduled = true
        let delay = backoffDelay()
        let version = attemptVersion
        attemptTask = Task { [weak self, clock] in
            try? await clock.sleep(for: delay)
            guard let self, self.attemptVersion == version else { return }
            guard self.portalRenderingEnabled else {
                self.attemptScheduled = false
                self.clear()
                return
            }
            self.attemptScheduled = false
            self.attempt()
        }
    }

    private func backoffDelay() -> Duration {
        guard stalledAttemptCount > 0 else { return .zero }
        let baseDelay = 0.01
        let exponent = min(stalledAttemptCount - 1, 5)
        let seconds = min(0.25, baseDelay * pow(2.0, Double(exponent)))
        return .seconds(seconds)
    }

    // MARK: - Attempt

    /// Runs one follow-up pass. Exposed for the
    /// `debugAttemptEventDrivenLayoutFollowUpForTesting()` hook. Legacy
    /// `Workspace.attemptEventDrivenLayoutFollowUp()`.
    public func attempt() {
        guard let host else { return }
        guard observation != nil, !isAttempting else { return }
        guard portalRenderingEnabled else {
            clear()
            host.layoutFollowUpHideAllPortals()
            return
        }
        isAttempting = true
        defer { isAttempting = false }

        host.layoutFollowUpFlushWindowLayouts()

        let geometryPendingBefore = needsGeometryPass
        let terminalPortalPendingBefore = host.layoutFollowUpTerminalPortalVisibilityNeedsFollowUp()
        let browserVisibilityPendingBefore = host.layoutFollowUpBrowserPortalVisibilityNeedsFollowUp()
        let terminalFocusPendingBefore = terminalFocusNeedsFollowUp()
        let browserPanelPendingBefore = browserPanelNeedsFollowUp()
        let browserExitPendingBefore = browserExitFocusPanelId != nil
        let reparentFocusPendingBefore = !pendingReparentFocusSuppressionViews.isEmpty

        if needsGeometryPass {
            needsGeometryPass = host.layoutFollowUpReconcileTerminalGeometryPass()
        }

        if let terminalFocusPanelId {
            if host.layoutFollowUpEnsureTerminalFocus(panelId: terminalFocusPanelId) {
                self.terminalFocusPanelId = nil
            }
        }

        host.layoutFollowUpReconcileTerminalPortalVisibility()
        let terminalPortalPending = host.layoutFollowUpTerminalPortalVisibilityNeedsFollowUp()
        clearReadyPendingReparentFocusSuppressions(reason: "workspace.layoutAttempt")
        let reparentFocusPending = !pendingReparentFocusSuppressionViews.isEmpty

        let reason = reason ?? "workspace.layout"
        host.layoutFollowUpReconcileBrowserPortalVisibility(reason: reason)
        let browserVisibilityPending = host.layoutFollowUpBrowserPortalVisibilityNeedsFollowUp()

        if let browserPanelId {
            if host.layoutFollowUpReconcilePendingBrowserPanel(panelId: browserPanelId, reason: reason) {
                self.browserPanelId = nil
            }
        }

        if let browserExitFocusPanelId {
            if !host.layoutFollowUpReconcileBrowserExitFocus(panelId: browserExitFocusPanelId) {
                self.browserExitFocusPanelId = nil
            }
        }

        let terminalFocusPending = terminalFocusNeedsFollowUp()
        let browserPanelPending = browserPanelNeedsFollowUp()
        let browserExitPending = browserExitFocusPanelId != nil
        let needsMoreWork =
            needsGeometryPass ||
            terminalPortalPending ||
            browserVisibilityPending ||
            terminalFocusPending ||
            browserPanelPending ||
            browserExitPending ||
            reparentFocusPending

        if !needsMoreWork {
            clear()
            return
        }

        let didMakeProgress =
            (geometryPendingBefore && !needsGeometryPass) ||
            (terminalPortalPendingBefore && !terminalPortalPending) ||
            (browserVisibilityPendingBefore && !browserVisibilityPending) ||
            (terminalFocusPendingBefore && !terminalFocusPending) ||
            (browserPanelPendingBefore && !browserPanelPending) ||
            (browserExitPendingBefore && !browserExitPending) ||
            (reparentFocusPendingBefore && !reparentFocusPending)

        if didMakeProgress {
            stalledAttemptCount = 0
            scheduleAttempt()
        } else {
            stalledAttemptCount += 1
        }
    }

    // MARK: - Moved-terminal refresh

    /// Forces a post-move terminal refresh: a reattach plus two deferred geometry
    /// + redraw passes (one on the next turn, one after a further 0.03 s) so rapid
    /// split close/reparent sequences still get a post-layout redraw. Legacy
    /// `Workspace.scheduleMovedTerminalRefresh(panelId:)`, whose two
    /// `DispatchQueue.main.asyncAfter` passes (`runRefreshPass(0)` and
    /// `runRefreshPass(0.03)`) are replaced by `Clock.sleep` tasks.
    /// Holds no follow-up state; it is a fire-and-forget refresh that lives here
    /// because it is part of the same render-adjacent post-move reconcile family.
    ///
    /// **Both passes are deferred, including the first.** Legacy's
    /// `runRefreshPass(0)` used `asyncAfter(deadline: .now() + 0)`, which enqueues
    /// the work for the NEXT main-runloop turn rather than running it inline; only
    /// the second pass added the further 0.03 s. The sole caller is the
    /// `splitTabBar(_:didMoveTab:fromPane:toPane:)` bonsplit delegate callback,
    /// which fires synchronously during a tab-move/split-tree mutation, so running
    /// `reconcileGeometryNow()` + `forceRefresh()` inline would re-enter AppKit
    /// layout during the move — exactly the re-entrancy this subsystem defers to
    /// avoid (see `begin()`). The first pass therefore sleeps `.zero` (the faithful
    /// `asyncAfter(0)` mapping), and the second sleeps `0.03`.
    public func scheduleMovedTerminalRefresh(panelId: UUID) {
        guard let host, host.layoutFollowUpIsTerminalPanel(panelId: panelId) else { return }

        // Force an NSViewRepresentable update after drag/move reparenting. This
        // keeps portal host binding current when a pane auto-closes during tab moves.
        host.layoutFollowUpRequestMovedTerminalReattach(panelId: panelId)

        // Run once on the next turn and once after 0.03 s so rapid split
        // close/reparent sequences still get a post-layout redraw. The first pass
        // is deferred (not inline) to match legacy `asyncAfter(0)` and avoid
        // re-entering AppKit layout inside the delegate callback that calls this.
        Task { [weak self, clock] in
            try? await clock.sleep(for: .zero)
            self?.host?.layoutFollowUpRefreshMovedTerminal(panelId: panelId)
        }
        Task { [weak self, clock] in
            try? await clock.sleep(for: .seconds(0.03))
            self?.host?.layoutFollowUpRefreshMovedTerminal(panelId: panelId)
        }
    }

    private func terminalFocusNeedsFollowUp() -> Bool {
        guard let terminalFocusPanelId else { return false }
        return host?.layoutFollowUpTerminalFocusNeedsFollowUp(panelId: terminalFocusPanelId) ?? false
    }

    private func browserPanelNeedsFollowUp() -> Bool {
        guard let browserPanelId else { return false }
        return host?.layoutFollowUpBrowserPanelNeedsFollowUp(panelId: browserPanelId) ?? false
    }
}

import AppKit
import Foundation
import CmuxTerminal

// `RendererRealizationPlannerInput` and the pure `RendererRealizationPlanner`
// policy live in RendererRealizationPlanner.swift.

struct RendererRealizationMemoryPressureReclaimResult: Equatable, Sendable {
    let reclaimedCount: Int
    let retryCandidateCount: Int

    static let empty = RendererRealizationMemoryPressureReclaimResult(
        reclaimedCount: 0,
        retryCandidateCount: 0
    )

    func detail(prefix: String) -> String {
        guard retryCandidateCount > 0 else { return prefix }
        return "\(prefix) retryCandidates=\(retryCandidateCount)"
    }
}

/// Releases the GPU renderer (Metal swap chain / IOSurface, ~40MB each) of
/// terminal surfaces that have been offscreen and idle, while keeping their PTY
/// and terminal state alive. The renderer is rebuilt on re-show via
/// `TerminalSurface.ensureRendererPresented()` driven from `setVisibleInUI(true)`.
///
/// macOS-only (AppKit). Sibling of `AgentHibernationController`, but
/// non-destructive: no process is killed, so it is safe to default ON.
@MainActor
final class RendererRealizationController {
    static let shared = RendererRealizationController()

    private let timerQueue = DispatchQueue(label: "com.cmux.renderer-realization", qos: .utility)
    private let systemMemoryPressureRetryPasses = 2
    private var timer: DispatchSourceTimer?
    private var reclaimDeadlineTask: Task<Void, Never>?
    private var reclaimDeadlineGeneration: UInt64 = 0
    private var scheduledReclaimDeadline: TimeInterval?
    private var settingsObserver: NSObjectProtocol?
    private var portalVisibilityObserver: NSObjectProtocol?
    private var portalVisibilityEvaluationTask: Task<Void, Never>?
    private var systemMemoryPressureRetryTask: Task<Void, Never>?

    private init() {}

    func start() {
        if settingsObserver == nil {
            // An immediate pass when the setting changes (command palette /
            // cmux.json post this). The always-on timer below is the safety net
            // for write paths that do NOT post it (the Settings-window toggle
            // writes the default directly), so re-enabling always takes effect.
            settingsObserver = NotificationCenter.default.addObserver(
                forName: RendererRealizationSettings.didChangeNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    RendererRealizationController.shared.schedulePortalVisibilityEvaluation()
                }
            }
        }
        if portalVisibilityObserver == nil {
            // Visibility transitions are the authoritative start and ranking
            // events for renderer idleness. Evaluate immediately so an older
            // hidden surface can leave the warm set, then arm the exact next
            // idle deadline instead of waiting for the coarse safety timer.
            portalVisibilityObserver = NotificationCenter.default.addObserver(
                forName: .terminalPortalVisibilityDidChange,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    RendererRealizationController.shared.evaluate(now: Date())
                }
            }
        }
        ensureTimerRunning()
        evaluate(now: Date())
    }

    func stop() {
        timer?.cancel()
        timer = nil
        cancelReclaimDeadlineTask()
        portalVisibilityEvaluationTask?.cancel()
        portalVisibilityEvaluationTask = nil
        systemMemoryPressureRetryTask?.cancel()
        systemMemoryPressureRetryTask = nil
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
        if let portalVisibilityObserver {
            NotificationCenter.default.removeObserver(portalVisibilityObserver)
            self.portalVisibilityObserver = nil
        }
    }

    /// This coarse timer is a safety net for direct UserDefaults writes and
    /// failed-release retries. Normal reclamation is scheduled at the exact idle
    /// deadline after a visibility transition. `evaluate` reads `enabled` fresh
    /// each pass, so re-enabling through a write path without a notification
    /// still takes effect without a relaunch. Disabled passes continue repairing
    /// visible surfaces whose compatibility rebuild was not acknowledged.
    private func ensureTimerRunning() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + 10, repeating: 20)
        timer.setEventHandler {
            let now = Date()
            Task { @MainActor in
                RendererRealizationController.shared.evaluate(now: now)
            }
        }
        timer.resume()
        self.timer = timer
    }

    /// Repairs only the surface whose renderer reported activity after a
    /// compatibility rebuild was not acknowledged.
    func scheduleRendererPresentationRepair(surfaceID: UUID) {
        guard let surface = GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: surfaceID) else { return }
        surface.retryRendererPresentationAfterActivity()
    }

    @discardableResult
    func reclaimForSystemMemoryPressure(
        now: Date,
        onRetryResult: (@MainActor (RendererRealizationMemoryPressureReclaimResult, Date) -> Void)? = nil
    ) -> RendererRealizationMemoryPressureReclaimResult {
        let result = evaluate(
            now: now,
            trigger: .systemMemoryPressure,
            remainingSystemMemoryPressureRetries: systemMemoryPressureRetryPasses,
            onSystemMemoryPressureRetryResult: onRetryResult
        )
        scheduleNextReclaimDeadline(now: now)
        return result
    }

    /// Run one reclamation pass. Internal so a unit/integration test can drive it
    /// deterministically without the timer.
    @discardableResult
    func evaluate(now: Date) -> Int {
        let reclaimedCount = evaluate(now: now, trigger: .scheduled).reclaimedCount
        scheduleNextReclaimDeadline(now: now)
        return reclaimedCount
    }

    /// Returns the next future eligibility deadline for any hidden realized
    /// renderer. Already-eligible surfaces are handled by the current pass and
    /// omitted here so a warm renderer cannot create an immediate timer loop.
    nonisolated static func nextScheduledReclaimDeadline(
        inputs: [RendererRealizationPlannerInput],
        settings: RendererRealizationSettings.Values,
        now: TimeInterval
    ) -> TimeInterval? {
        guard settings.enabled else { return nil }
        return inputs.lazy
            .filter { $0.isRealized && !$0.isVisible }
            .map { $0.lastVisibleAt + settings.idleSeconds }
            .filter { $0 > now }
            .min()
    }

    @discardableResult
    private func evaluate(
        now: Date,
        trigger: RendererRealizationReclaimTrigger,
        remainingSystemMemoryPressureRetries: Int = 0,
        onSystemMemoryPressureRetryResult: (@MainActor (RendererRealizationMemoryPressureReclaimResult, Date) -> Void)? = nil
    ) -> RendererRealizationMemoryPressureReclaimResult {
        // Iterate the global registry rather than re-deriving per-workspace
        // visibility: each TerminalSurface carries its own authoritative
        // on-screen flag (driven by setVisibleInUI, the same signal that drives
        // occlusion), so we never misclassify a visible surface as offscreen.
        let surfaces = GhosttyApp.terminalSurfaceRegistry.allTerminalSurfaces()

        // Keep currently-visible surfaces ranked at the top of the warm set, and
        // ensure every visible renderer has completed presentation. This covers
        // both a reclaimed renderer and a hidden-at-birth renderer whose first
        // rebuild publication was not acknowledged. Presentation repair
        // remains active even when reclamation is disabled because visible
        // rendering must not depend on a memory-saving preference.
        for surface in surfaces where surface.isRendererPortalVisible {
            surface.noteBecameVisibleForRendererReclamation()
            if surface.hasLiveSurface, !surface.isRendererPresented {
                surface.ensureRendererPresented()
            }
        }

        let settings = RendererRealizationSettings.values()
        guard settings.enabled else { return .empty }

        let inputs = surfaces.compactMap { surface -> RendererRealizationPlannerInput? in
            guard surface.hasLiveSurface else { return nil }
            return RendererRealizationPlannerInput(
                surfaceId: surface.id,
                isVisible: surface.isRendererPortalVisible,
                isRealized: surface.isRendererRealized,
                lastVisibleAt: surface.rendererLastVisibleAt
            )
        }

        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: inputs,
            settings: settings,
            now: now.timeIntervalSince1970,
            trigger: trigger
        )
        guard !selected.isEmpty else { return .empty }
        var reclaimedCount = 0
        var retryCandidateCount = 0
        for surface in surfaces where selected.contains(surface.id) {
            if surface.releaseRenderer() {
                reclaimedCount += 1
            }
            // A compatibility rejection leaves the renderer realized. Retry
            // with the pressure policy; scheduled policy may keep recent
            // hidden surfaces warm and skip the exact surface pressure selected.
            if trigger == .systemMemoryPressure,
               !surface.isRendererPortalVisible,
               surface.isRendererRealized {
                retryCandidateCount += 1
            }
        }

        let result = RendererRealizationMemoryPressureReclaimResult(
            reclaimedCount: reclaimedCount,
            retryCandidateCount: retryCandidateCount
        )

        if retryCandidateCount > 0, remainingSystemMemoryPressureRetries > 0 {
            scheduleSystemMemoryPressureRetry(
                remainingRetries: remainingSystemMemoryPressureRetries - 1,
                onRetryResult: onSystemMemoryPressureRetryResult
            )
        }
        return result
    }

    private func scheduleSystemMemoryPressureRetry(
        remainingRetries: Int,
        onRetryResult: (@MainActor (RendererRealizationMemoryPressureReclaimResult, Date) -> Void)?
    ) {
        systemMemoryPressureRetryTask?.cancel()
        systemMemoryPressureRetryTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.systemMemoryPressureRetryTask = nil
            let retryResult = self.evaluate(
                now: Date(),
                trigger: .systemMemoryPressure,
                remainingSystemMemoryPressureRetries: remainingRetries,
                onSystemMemoryPressureRetryResult: onRetryResult
            )
            guard !Task.isCancelled else { return }
            if retryResult.reclaimedCount > 0 {
                onRetryResult?(retryResult, Date())
            }
            self.scheduleNextReclaimDeadline(now: Date())
        }
    }

    private func scheduleNextReclaimDeadline(now: Date) {
        let settings = RendererRealizationSettings.values()
        let inputs = GhosttyApp.terminalSurfaceRegistry.allTerminalSurfaces().compactMap {
            surface -> RendererRealizationPlannerInput? in
            guard surface.hasLiveSurface else { return nil }
            return RendererRealizationPlannerInput(
                surfaceId: surface.id,
                isVisible: surface.isRendererPortalVisible,
                isRealized: surface.isRendererRealized,
                lastVisibleAt: surface.rendererLastVisibleAt
            )
        }
        guard let deadline = Self.nextScheduledReclaimDeadline(
            inputs: inputs,
            settings: settings,
            now: now.timeIntervalSince1970
        ) else {
            cancelReclaimDeadlineTask()
            return
        }

        if let scheduledReclaimDeadline,
           abs(scheduledReclaimDeadline - deadline) < 0.001 {
            return
        }

        cancelReclaimDeadlineTask()
        let generation = reclaimDeadlineGeneration
        let delay = max(0, deadline - now.timeIntervalSince1970)
        scheduledReclaimDeadline = deadline
        reclaimDeadlineTask = Task { @MainActor [weak self] in
            do {
                try await ContinuousClock().sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self,
                  self.reclaimDeadlineGeneration == generation,
                  self.scheduledReclaimDeadline == deadline else { return }
            self.reclaimDeadlineTask = nil
            self.scheduledReclaimDeadline = nil
            self.evaluate(now: Date())
        }
    }

    /// A workspace transition can hide and reveal many portals synchronously.
    /// Coalesce their notifications into one global planner pass after the
    /// current actor batch instead of scanning and sorting the registry once
    /// per surface.
    private func schedulePortalVisibilityEvaluation() {
        guard portalVisibilityEvaluationTask == nil else { return }
        portalVisibilityEvaluationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.portalVisibilityEvaluationTask = nil
            self.evaluate(now: Date())
        }
    }

    private func cancelReclaimDeadlineTask() {
        reclaimDeadlineGeneration &+= 1
        reclaimDeadlineTask?.cancel()
        reclaimDeadlineTask = nil
        scheduledReclaimDeadline = nil
    }
}

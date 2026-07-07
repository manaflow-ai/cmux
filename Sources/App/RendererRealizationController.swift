import AppKit
import Foundation
import CmuxTerminal

// `RendererRealizationPlannerInput` and the pure `RendererRealizationPlanner`
// policy live in RendererRealizationPlanner.swift.

/// Periodically releases the GPU renderer (Metal swap chain / IOSurface, ~40MB
/// each) of terminal surfaces that have been offscreen and idle, while keeping
/// their PTY and terminal state alive. The renderer is rebuilt on re-show via
/// `TerminalSurface.realizeRenderer()` driven from `setVisibleInUI(true)`.
///
/// macOS-only (AppKit). Sibling of `AgentHibernationController`, but
/// non-destructive: no process is killed, so it is safe to default ON.
@MainActor
final class RendererRealizationController {
    static let shared = RendererRealizationController()

    private let timerQueue = DispatchQueue(label: "com.cmux.renderer-realization", qos: .utility)
    private let systemMemoryPressureRetryPasses = 2
    private var timer: DispatchSourceTimer?
    private var settingsObserver: NSObjectProtocol?

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
                    RendererRealizationController.shared.evaluate(now: Date())
                }
            }
        }
        ensureTimerRunning()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
    }

    /// The timer always runs once started; `evaluate` reads `enabled` fresh each
    /// pass and no-ops when the feature is off. Keeping it running (rather than
    /// cancelling when disabled) means toggling the setting back on from any
    /// surface, including the Settings window which writes UserDefaults directly
    /// without posting a change notification, takes effect on the next pass
    /// instead of requiring a relaunch. The disabled-pass cost is a settings read
    /// plus an early return every 20s.
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

    /// Schedule a reclamation pass on the next main-actor turn. Called when a
    /// re-show realize enqueue dropped, so the controller re-realizes the
    /// now-visible-but-unrealized surface immediately rather than waiting for the
    /// periodic tick. Async (not re-entrant): the caller is already mid
    /// `realizeRenderer`.
    func scheduleImmediatePass() {
        Task { @MainActor in
            RendererRealizationController.shared.evaluate(now: Date())
        }
    }

    @discardableResult
    func reclaimForSystemMemoryPressure(now: Date) -> Int {
        evaluate(
            now: now,
            trigger: .systemMemoryPressure,
            remainingSystemMemoryPressureRetries: systemMemoryPressureRetryPasses
        )
    }

    /// Run one reclamation pass. Internal so a unit/integration test can drive it
    /// deterministically without the timer.
    @discardableResult
    func evaluate(now: Date) -> Int {
        evaluate(now: now, trigger: .scheduled)
    }

    @discardableResult
    private func evaluate(
        now: Date,
        trigger: RendererRealizationReclaimTrigger,
        remainingSystemMemoryPressureRetries: Int = 0
    ) -> Int {
        let settings = RendererRealizationSettings.values()
        guard settings.enabled else { return 0 }

        // Iterate the global registry rather than re-deriving per-workspace
        // visibility: each TerminalSurface carries its own authoritative
        // on-screen flag (driven by setVisibleInUI, the same signal that drives
        // occlusion), so we never misclassify a visible surface as offscreen.
        let surfaces = GhosttyApp.terminalSurfaceRegistry.allTerminalSurfaces()

        // Keep currently-visible surfaces ranked at the top of the warm set, and
        // re-realize any that are visible but not realized. setVisibleInUI
        // normally realizes on re-show, but its enqueue can drop (a `.forever`
        // mailbox push can fail on a spurious wakeup while full), which would
        // leave a visible terminal drawing into a defunct swap chain. This pass
        // self-heals that within one tick. realizeRenderer is idempotent.
        for surface in surfaces where surface.isRendererPortalVisible {
            surface.noteBecameVisibleForRendererReclamation()
            if surface.hasLiveSurface, !surface.isRendererRealized {
                surface.realizeRenderer()
            }
        }

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
        guard !selected.isEmpty else { return 0 }
        var needsSystemMemoryPressureRetry = false
        var reclaimedCount = 0
        for surface in surfaces where selected.contains(surface.id) {
            surface.releaseRenderer()
            reclaimedCount += 1
            // A dropped Ghostty mailbox enqueue leaves the renderer realized.
            // Retry with the pressure policy; scheduled policy may keep recent
            // hidden surfaces warm and skip the exact surface pressure selected.
            if trigger == .systemMemoryPressure,
               !surface.isRendererPortalVisible,
               surface.isRendererRealized {
                needsSystemMemoryPressureRetry = true
            }
        }

        if needsSystemMemoryPressureRetry, remainingSystemMemoryPressureRetries > 0 {
            Task { @MainActor in
                RendererRealizationController.shared.evaluate(
                    now: Date(),
                    trigger: .systemMemoryPressure,
                    remainingSystemMemoryPressureRetries: remainingSystemMemoryPressureRetries - 1
                )
            }
        }
        return reclaimedCount
    }
}

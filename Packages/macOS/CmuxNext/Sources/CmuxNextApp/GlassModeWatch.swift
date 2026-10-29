import AppKit
import CmuxNextCompat
import CmuxNextDesign

/// Calls back when the glass mode pages draw (`GlassLensMode.current`) changes: the Debug choice `glass.lens`,
/// Reduce Transparency (system or Debug override) or Low Power Mode. Events only, nothing polls.
final class GlassModeWatch {
    private var shown: GlassLensMode
    private let onChange: @MainActor () -> Void
    /// The glass tunable's observation loop (read by the release tests).
    private(set) var settings: Task<Void, Never>?
    private var lowPower: LowPowerModeObservation?
    private var display: MainActorObservation?

    init(onChange: @escaping @MainActor () -> Void) {
        shown = .current
        self.onChange = onChange
        settings = Task { [weak self] in
            for await _ in ObservationStream({ GlassLensMode.tunable.value }) { self?.check() }
        }
        lowPower = LowPowerMode.system.observe { [weak self] _ in self?.check() }
        display = MainActorObservation(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, center: NSWorkspace.shared.notificationCenter) { [weak self] in
            self?.check()
        }
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // The settings task is Sendable and cancels from any thread: a release off main cleans up too.
    // `lowPower` and `display` stop themselves when released with this watch.
    nonisolated deinit {
        settings?.cancel()
    }

    /// Calls back when the mode is not the one last seen.
    func check() {
        let now = GlassLensMode.current
        guard now != shown else { return }
        shown = now
        onChange()
    }
}

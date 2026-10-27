import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextEnergy
import CmuxNextWakeups

/// Resolves the glass mode pages draw and calls back when it changes: the Debug choice `glass.lens`,
/// Reduce Transparency (system or Debug override) or the energy monitor's Low Power Mode (system or
/// `debug.low_power_mode`). Events only, nothing polls.
final class GlassModeWatch {
    /// The mode pages draw now (the App hands it to `ThemeStore.setGlassMode`).
    private(set) var mode: GlassLensMode
    private let store: TunableStore
    private let reduceTransparency: ReduceTransparency
    private let lowPowerMode: LowPowerMode
    private let onChange: @MainActor (GlassLensMode) -> Void
    /// Follows the glass tunable (read by the release tests).
    private(set) var settings: ServiceObservation<GlassLensMode>?
    private var lowPower: LowPowerModeObservation?
    private var display: AppearanceSignals.Subscription?

    /// - Parameters:
    ///   - store: Where the `glass.lens` choice lives.
    ///   - reduceTransparency: Reduce Transparency and its Debug override.
    ///   - signals: Where display option changes come from (the composition root's ``AppearanceSignals``).
    ///   - lowPowerMode: The app's Low Power Mode (its energy monitor's); the default, fixed off, is for tests.
    ///   - mainWork: The app's main-thread scheduler: a change of the tunable applies as one `visible` task on it.
    ///   - onChange: Called with the new mode when it is not the one last seen.
    init(store: TunableStore = .shared, reduceTransparency: ReduceTransparency = .shared,
         signals: AppearanceSignals = DesignSettings.shared.signals, lowPowerMode: LowPowerMode = LowPowerMode(enabled: false),
         mainWork: MainWorkScheduler, onChange: @escaping @MainActor (GlassLensMode) -> Void) {
        self.store = store
        self.reduceTransparency = reduceTransparency
        self.lowPowerMode = lowPowerMode
        mode = GlassLensMode.current(store: store, reduceTransparency: reduceTransparency, lowPowerMode: lowPowerMode.isEnabled)
        self.onChange = onChange
        // `visible`: pages draw the mode; a person's Debug choice flushes before its frame.
        settings = ServiceObservation(.visible, owner: "GlassModeWatch.tunable", on: mainWork) {
            GlassLensMode.tunable.value(in: store)
        } apply: { [weak self] _ in self?.check() }
        lowPower = lowPowerMode.observe { [weak self] _ in self?.check() }
        display = signals.subscribe([.displayOptions], owner: "GlassModeWatch") { [weak self] in
            self?.check()
        }
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // `settings`, `lowPower` and `display` stop themselves when released with this watch, on any thread.
    nonisolated deinit {}

    /// Calls back when the mode is not the one last seen.
    func check() {
        let now = GlassLensMode.current(store: store, reduceTransparency: reduceTransparency, lowPowerMode: lowPowerMode.isEnabled)
        guard now != mode else { return }
        mode = now
        onChange(now)
    }
}

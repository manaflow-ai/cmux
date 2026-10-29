#if DEBUG || CMUX_BENCH_HOOKS
package import CmuxNextWakeups

/// The `high-energy-tab` capture scene's renderer readings: one renderer per read tab, the busy tab's
/// at `share` of one core since the first reading and every other tab's idle, on a clock of its own. Installed on a
/// ``HighEnergyTabMonitor`` through its `measure` and `now` seams, so the scene needs no busy page and no minute of
/// waiting; everything else (the hidden tabs, the rule, the card's question) is the app's own.
@MainActor
package final class HighEnergySceneReadings {
    private let busy: String
    private let share: Double
    private var start: ContinuousClock.Instant = .now
    private var now: ContinuousClock.Instant = .now
    /// Each read tab's renderer, numbered as first met.
    private var renderers: [String: ProcessUsage.Renderer] = [:]

    package init(busy: String, share: Double) {
        self.busy = busy
        self.share = share
    }

    /// Replaces `monitor`'s readings and clock with these, and lands two readings a whole window apart, so `busy` has
    /// its share. The clock starts a window past the monitor's last reading: a real reading still out or just taken
    /// holds neither. Returns what puts the monitor's own readings and clock back.
    package func install(on monitor: HighEnergyTabMonitor) -> @MainActor () -> Void {
        let saved = (measure: monitor.measure, now: monitor.now)
        start = max(ContinuousClock.now, monitor.rule.lastReadingAt ?? .now) + HighEnergyTabs.window
        now = start
        monitor.now = { [self] in now }
        monitor.measure = { [self] keys, landed in landed(reading(of: keys)) }
        monitor.wake()
        now += HighEnergyTabs.window + .seconds(1)
        monitor.wake()
        return { [weak monitor] in
            monitor?.measure = saved.measure
            monitor?.now = saved.now
        }
    }

    func reading(of keys: [String]) -> SaverCPUFreeze.Reading {
        let busyCPU = (now - start) * share
        return SaverCPUFreeze.Reading(renderers: keys.map { key in
            let id = renderers[key] ?? ProcessUsage.Renderer(pid: Int32(renderers.count + 1), clientID: Int32(renderers.count + 1))
            renderers[key] = id
            return SaverCPUFreeze.Reading.Renderer(id: id, cpu: key == busy ? busyCPU : .zero, tabs: [key])
        }, at: now)
    }
}
#endif

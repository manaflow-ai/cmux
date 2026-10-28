import CmuxNextSettings
import CmuxNextWakeups
import Darwin

/// `debug.energy`'s `tabs`: each Chromium tab with the renderers that serve it.
extension EnergyReport {
    /// Each tab's renderers: the sampled tab renderers (``ProcessSample/rendererClientID``), matched by
    /// the pid of the tab's main frame and the client ids of its frames.
    static func tabUsage(_ tabs: [ProcessUsage.TabRenderers], processes: [ProcessSample]) -> [ProcessUsage.TabUsage] {
        guard !tabs.isEmpty else { return [] }
        let renderers: [(renderer: ProcessUsage.Renderer, usage: ProcessUsage)] = processes.compactMap { sample in
            sample.rendererClientID.map { (renderer: ProcessUsage.Renderer(pid: sample.usage.pid, clientID: $0), usage: sample.usage) }
        }
        return ProcessUsage.perTab(tabs, renderers: renderers)
    }

    /// One row of `tabs`: its renderers' usage summed, and each renderer with every tab it serves.
    static func tabJSON(_ tab: ProcessUsage.TabUsage) -> JSONValue {
        [
            "tab": .string(tab.tab), "title": .string(tab.title),
            "cpuMs": .number(Double(tab.cpuNanos) / 1e6),
            "energyNj": integer(tab.energyNanojoules),
            "interruptWakeups": integer(tab.interruptWakeups),
            "packageIdleWakeups": integer(tab.packageIdleWakeups),
            "renderers": .array(tab.renderers.map(rendererJSON)),
        ]
    }

    private static func rendererJSON(_ shared: ProcessUsage.SharedRenderer) -> JSONValue {
        [
            "pid": JSONValue(Int(truncatingIfNeeded: shared.renderer.pid)),
            "clientId": JSONValue(Int(truncatingIfNeeded: shared.renderer.clientID)),
            "cpuMs": .number(Double(shared.usage.cpuNanos) / 1e6),
            "energyNj": integer(shared.usage.energyNanojoules),
            "interruptWakeups": integer(shared.usage.interruptWakeups),
            "packageIdleWakeups": integer(shared.usage.packageIdleWakeups),
            "tabs": .array(shared.tabs.map(JSONValue.string)),
        ]
    }
}

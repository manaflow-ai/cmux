import CmuxNextSettings
import CmuxNextWakeups
import Darwin

/// `debug.energy`'s `tabs` (p14-energy-124): each Chromium tab with the renderers that serve it.
extension EnergyReport {
    /// The `processes` kind of a Chromium renderer helper.
    public static let rendererKind = "cef-renderer"

    /// Each tab's renderers: the sampled `cef-renderer` processes, each with the client id its argv
    /// names, and a tab's main-frame renderer that `processes` does not list, sampled now. Blocking
    /// system calls: off the main actor. `identify` and `sample` are seams for tests.
    static func tabUsage(_ tabs: [ProcessUsage.TabRenderers], processes: [ProcessSample],
                         identify: (pid_t) -> ProcessUsage.Renderer = ProcessUsage.Renderer.identify,
                         sample: (pid_t) -> ProcessUsage? = ProcessUsage.sample) -> [ProcessUsage.TabUsage] {
        guard !tabs.isEmpty else { return [] }
        var renderers = processes.filter { $0.kind == rendererKind }.map { (renderer: identify($0.usage.pid), usage: $0.usage) }
        var known = Set(renderers.map { $0.renderer.pid })
        for pid in tabs.compactMap(\.pid) where known.insert(pid).inserted {
            guard let usage = sample(pid) else { continue }
            renderers.append((renderer: ProcessUsage.Renderer(pid: pid, clientID: nil), usage: usage))
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
            "clientId": shared.renderer.clientID.map { JSONValue(Int(truncatingIfNeeded: $0)) } ?? .null,
            "cpuMs": .number(Double(shared.usage.cpuNanos) / 1e6),
            "energyNj": integer(shared.usage.energyNanojoules),
            "interruptWakeups": integer(shared.usage.interruptWakeups),
            "packageIdleWakeups": integer(shared.usage.packageIdleWakeups),
            "tabs": .array(shared.tabs.map(JSONValue.string)),
        ]
    }
}

import CmuxNextBrowser
import CmuxNextControl
import CmuxNextSettings
import CmuxNextResources
import CmuxNextWakeups
import Foundation

/// `resources` on the app control socket (`cmux rpc resources '{…}'`): the
/// numbers the hover cards show, as JSON. It takes two samples
/// `interval_ms` apart (default 1000, 100 to 1500) because CPU is a
/// percentage over an interval; nothing is sampled before or after.
///
/// Params: `tab` (tab id) or `workspace` (workspace id or key); neither
/// means the workspace the active window shows.
enum ResourceControl {
    /// The longest interval (1.5 s) plus two samples, each bounded by the
    /// 1 s daemon request deadline, plus margin.
    static let deadline: Duration = .seconds(5)

    static func run(_ params: [String: JSONValue], services: AppServices?) async throws -> JSONValue {
        guard let services else { throw ControlError(code: "unavailable", message: RefusalStrings.noWindowShowsWorkspace) }
        let target = try await MainActor.run { try Self.target(params, services: services) }
        let milliseconds = min(max(params["interval_ms"]?.intValue ?? 1000, 100), 1500)
        let first = await services.resources.sample(target)
        await waitOnce(.milliseconds(milliseconds))
        let second = await services.resources.sample(target)
        let report = ResourceAggregator.report(current: second, previous: first)
        return json(target: target, intervalMilliseconds: milliseconds, report: report, current: second, previous: first)
    }

    @MainActor
    private static func target(_ params: [String: JSONValue], services: AppServices) throws -> ResourceTarget {
        if let raw = params["tab"]?.stringValue {
            let tab = normalizedTabID(raw)
            guard services.locateTabOnAnyMachine(tab) != nil else { throw ControlError(code: "not_found", message: RefusalStrings.noTab(tab)) }
            return .tab(tab)
        }
        if let raw = params["workspace"]?.stringValue {
            let workspace = services.machines.workspace(id: raw) != nil ? raw : raw.lowercased()
            guard services.machines.workspace(id: workspace) != nil else {
                throw ControlError(code: "not_found", message: RefusalStrings.noWorkspace(workspace))
            }
            return .workspace(workspace)
        }
        guard let id = services.windows.active?.state.workspaceID ?? services.windows.controllers.first?.state.workspaceID else {
            throw ControlError(code: "not_found", message: RefusalStrings.noWindowShowsWorkspace)
        }
        return .workspace(id)
    }

    /// A tab id (`tab_…`), or the surface UUID the cmux CLI prints (the
    /// same 32 hex digits, with dashes).
    static func normalizedTabID(_ raw: String) -> String {
        let hex = raw.replacingOccurrences(of: "-", with: "").lowercased()
        guard !raw.hasPrefix("tab_"), hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return raw }
        return "tab_" + hex
    }

    /// One wait for the second sample: a one-shot deadline, not a sleep.
    private static func waitOnce(_ delay: Duration) async {
        let timer = DemandTimer(owner: "Resources.control")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            timer.schedule(after: delay) { continuation.resume() }
        }
        _ = timer
    }

    private static func json(target: ResourceTarget, intervalMilliseconds: Int, report: ResourceReport,
                             current: ResourceSampleSet, previous: ResourceSampleSet) -> JSONValue {
        func process(_ key: ProcessKey, role: String? = nil) -> JSONValue? {
            guard let sample = current.samples[key] else { return nil }
            var object: [String: JSONValue] = [
                "pid": JSONValue(Int(key.pid)), "host": .string(key.host), "name": .string(sample.name),
                "memory_bytes": .number(Double(sample.memoryBytes)),
            ]
            if let before = previous.samples[key] {
                object["cpu_percent"] = .number(percent(ResourceAggregator.share(sample, since: before)))
            }
            if let role { object["role"] = .string(role) }
            return .object(object)
        }
        let sharedKeys = Set(current.shared.map(\.key))
        let tabs: [JSONValue] = zip(report.tabs, current.tabs).map { tab, sources in
            var object = usage(tab.usage)
            object["id"] = .string(tab.id)
            object["title"] = .string(tab.title)
            object["kind"] = .string(tab.kind.rawValue)
            object["available"] = .bool(tab.available)
            object["shared_with_tabs"] = JSONValue(tab.sharedWithTabs)
            object["estimated_app_bytes"] = .number(Double(sources.estimatedAppBytes))
            object["processes"] = .array(sources.processes.filter { !sharedKeys.contains($0) }.compactMap { process($0) })
            object["text"] = .string(tab.available ? ResourceFormat.line(tab.usage) : "")
            return .object(object)
        }
        var total = usage(report.total)
        total["processes"] = JSONValue(report.processCount)
        var shared = usage(report.shared)
        shared["roles"] = .array(report.sharedRoles.map { .string($0.rawValue) })
        shared["processes"] = .array(current.shared.compactMap { process($0.key, role: $0.role.rawValue) })
        shared["text"] = .string(report.sharedRoles.isEmpty ? "" : ResourceFormat.shared(report.shared, roles: report.sharedRoles))
        let targetJSON: JSONValue = switch target {
        case .tab(let id): ["kind": "tab", "id": .string(id)]
        case .workspace(let id): ["kind": "workspace", "id": .string(id)]
        case .everything: ["kind": "everything"]
        }
        return [
            "target": targetJSON,
            "interval_ms": JSONValue(intervalMilliseconds),
            "total": .object(total),
            "shared": .object(shared),
            "tabs": .array(tabs),
            "top": .array(report.topConsumers(3).map { .string($0.id) }),
            "text": .string(ResourceFormat.line(report.total)),
        ]
    }

    private static func usage(_ usage: ResourceUsage) -> [String: JSONValue] {
        [
            "cpu_percent": usage.cpu.map { .number(percent($0)) } ?? .null,
            "memory_bytes": .number(Double(usage.memoryBytes)),
        ]
    }

    /// Percent of one core, rounded to 0.1 like Activity Monitor.
    private static func percent(_ share: Double) -> Double {
        (share * 1000).rounded() / 10
    }
}

/// `renderers.list` (`cmux app renderers`, Release too): ``CEFEngine/rendererReport(owners:intervalMs:)``
/// plus each page's owning tab. `interval_ms`: CPU interval, default 500, 0 for none, at most 1500.
extension ResourceControl {
    static let renderersDeadline: Duration = .seconds(4)

    @MainActor
    static func renderers(_ params: [String: JSONValue], services: AppServices?) async throws -> JSONValue {
        guard let services else { return .null }
        let (milliseconds, owners) = (min(max(params["interval_ms"]?.intValue ?? 500, 0), 1500), rendererOwners(services))
        return try await JSONValue.parse(CEFRendererReport.encoded(services.cache.cef.rendererReport(owners: owners, intervalMs: milliseconds)))
    }

    @MainActor // browser tabs by browser id, agent tabs by the browser showing their page
    private static func rendererOwners(_ services: AppServices) -> [Int32: CEFRendererOwner] {
        let browsers = services.cache.browsers.compactMap { key, entry in (entry.tab as? CEFTab)?.browserID.map { ($0, key, "browser") } }
        let agents = (services.madeAgentTabs?.views.bare ?? [:]).compactMap { key, view in services.cache.cef.browserID(showing: view.focusTarget).map { ($0, key, "agent") } }
        return Dictionary((browsers + agents).map { browser, key, kind in
            var owner = CEFRendererOwner(kind: kind, tab: key)
            if let (tab, pane) = services.locateTab(key) {
                let found = services.machines.daemons.lazy.compactMap { daemon in daemon.store.workspace(holdingTab: tab.id).map { (daemon.machineID, $0) } }.first
                (owner.tab, owner.tabTitle, owner.pane, owner.session) = (tab.id, tab.displayTitle, pane.id, tab.agentSession?.session)
                (owner.workspace, owner.workspaceTitle, owner.machine) = (found?.1.id, found?.1.displayName, found?.0)
            }
            return (browser, owner)
        }, uniquingKeysWith: { $1 })
    }
}

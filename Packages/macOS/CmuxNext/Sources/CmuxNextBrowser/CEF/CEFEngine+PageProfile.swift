import CmuxNextWakeups
public import Foundation

/// One cmux page's JS heap, Chromium counters and optional CPU profile (`renderers.profile`, `cmux app renderers
/// profile`): what a page holds and spends, so a renderer at GBs or at 100% CPU on a person's Mac is a page and a call
/// stack, not a guess (2026-11-11: an agent-page renderer at 4.5 GB and 140% CPU with nine pages in it, and nothing in
/// a Release build said which one held it).
public nonisolated struct CEFPageProfile: Sendable {
    /// The JS heap after a full GC (`HeapProfiler.collectGarbage`, then `Runtime.getHeapUsage`): what the page holds.
    public var heapUsedBytes: Double = 0
    public var heapTotalBytes: Double = 0
    /// `Performance.getMetrics`: Nodes, JSEventListeners, Documents, LayoutCount, TaskDuration, ScriptDuration...
    public var metrics: [String: Double] = [:]
    /// The V8 CPU profile as DevTools reads it (`Profiler.stop`'s `profile`, JSON), when one was taken.
    public var cpuProfile: String?
    /// The functions with the most self time in it, `name file:line`, idle and program left out.
    public var topSelf: [(name: String, ms: Double)] = []
}

public enum CEFPageProfileError: Error, CustomStringConvertible {
    case pageGone(Int32)
    public var description: String {
        switch self { case .pageGone(let browser): "page \(browser) closed while it was profiled" }
    }
}

/// `renderers.profile`'s answer (snake_case JSON, ``encoded(_:)``): the page and its profile, or why there is none.
public nonisolated struct CEFPageProfileReport: Encodable, Sendable {
    public struct Function: Encodable, Sendable {
        public var ms: Double
        public var function: String
    }

    public var browser: Int32?
    public var url: String?
    public var hidden: Bool?
    public var heapUsedBytes: Double?
    public var heapTotalBytes: Double?
    public var metrics: [String: Double]?
    /// V8's CPU profile JSON; the CLI moves it to a `.cpuprofile` file.
    public var cpuProfile: String?
    public var topSelfMs: [Function]?
    public var error: String?

    public static func encoded(_ report: CEFPageProfileReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(report)
    }
}

extension CEFEngine {
    /// The hidden defaults key that turns `renderers.profile` on (`defaults write <bundle id> CMUXPageProfiler -bool
    /// true`): it reads a page's heap and can profile it, so a person turns it on for a diagnosis.
    public static let pageProfilerDefaultsKey = "CMUXPageProfiler"

    /// `renderers.profile {browser, seconds?}`: off unless ``pageProfilerDefaultsKey`` is set; only cmux's own pages
    /// (`cmux-page://`), never a browser tab; `seconds` is 0...30.
    public func pageProfileReport(browser id: Int?, seconds: Int?, defaults: UserDefaults = .standard) async -> CEFPageProfileReport {
        var report = CEFPageProfileReport()
        guard defaults.bool(forKey: Self.pageProfilerDefaultsKey) else {
            report.error = "the page profiler is off: defaults write \(Bundle.main.bundleIdentifier ?? "<bundle id>") \(Self.pageProfilerDefaultsKey) -bool true"
            return report
        }
        guard let id, let browser = Int32(exactly: id) else {
            report.error = "browser (a browser id from cmux app renderers) is required"
            return report
        }
        guard let page = rendererPages.first(where: { $0.browserID == browser }) else {
            report.error = "no live page \(browser)"
            return report
        }
        guard page.origin.hasPrefix("cmux-page://") else {
            report.error = "only cmux's own pages"
            return report
        }
        (report.browser, report.url, report.hidden) = (browser, page.url, page.hidden)
        do {
            let profile = try await pageProfile(browserID: browser, seconds: min(max(seconds ?? 0, 0), 30))
            (report.heapUsedBytes, report.heapTotalBytes, report.metrics) = (profile.heapUsedBytes, profile.heapTotalBytes, profile.metrics)
            report.cpuProfile = profile.cpuProfile
            if profile.cpuProfile != nil { report.topSelfMs = profile.topSelf.map { .init(ms: $0.ms, function: $0.name) } }
        } catch {
            report.error = String(describing: error)
        }
        return report
    }

    /// A DevTools method on one of cmux's own live pages (`cmux-page://`, never a browser tab) by browser id: its JSON
    /// reply, or why there is none (`debug.cef_page_devtools`, the idle bench's page metrics and CPU profile).
    public func cmuxPageDevTools(browser id: Int?, method: String?, params: [String: any Sendable]) async -> (result: String?, error: String?) {
        guard let id, let browser = Int32(exactly: id), let method else { return (nil, "browser (a browser id) and method are required") }
        guard let page = rendererPages.first(where: { $0.browserID == browser }) else { return (nil, "no live page \(browser)") }
        guard page.origin.hasPrefix("cmux-page://") else { return (nil, "only cmux's own pages") }
        var answer: (result: String?, error: String?) = (nil, "no live page \(browser)")
        do {
            if let reply = try await devTools(browserID: browser, method: method, params: params) { answer = (reply, nil) }
        } catch {
            answer = (nil, String(describing: error))
        }
        return answer
    }

    /// Profiles the live page `browserID` with DevTools: the heap after GC and the page's counters, and over `seconds`
    /// (0: none) a CPU profile at 1 ms sampling. Read on request only; the caller checks that the page is cmux's own.
    public func pageProfile(browserID: Int32, seconds: Int) async throws -> CEFPageProfile {
        func call(_ method: String, _ arguments: [String: any Sendable] = [:]) async throws -> [String: Any] {
            guard let reply = try await devTools(browserID: browserID, method: method, params: arguments) else {
                throw CEFPageProfileError.pageGone(browserID)
            }
            return (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any] ?? [:]
        }
        var profile = CEFPageProfile()
        _ = try await call("HeapProfiler.enable")
        _ = try await call("HeapProfiler.collectGarbage")
        let heap = try await call("Runtime.getHeapUsage")
        profile.heapUsedBytes = (heap["usedSize"] as? Double) ?? 0
        profile.heapTotalBytes = (heap["totalSize"] as? Double) ?? 0
        _ = try await call("HeapProfiler.disable")
        _ = try await call("Performance.enable", ["timeDomain": "threadTicks"])
        let metrics = (try await call("Performance.getMetrics")["metrics"] as? [[String: Any]]) ?? []
        for metric in metrics {
            if let name = metric["name"] as? String { profile.metrics[name] = (metric["value"] as? Double) ?? 0 }
        }
        _ = try await call("Performance.disable")
        guard seconds > 0 else { return profile }
        _ = try await call("Profiler.enable")
        _ = try await call("Profiler.setSamplingInterval", ["interval": 1000])
        _ = try await call("Profiler.start")
        // The profile window: one DemandTimer deadline (no sleep), counted in the wakeup ledger.
        let window = DemandTimer(owner: "renderers.profile")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            window.schedule(after: .seconds(seconds)) { done.resume() }
        }
        let stopped = try await call("Profiler.stop")
        _ = try await call("Profiler.disable")
        let cpu = stopped["profile"] as? [String: Any] ?? [:]
        profile.cpuProfile = (try? JSONSerialization.data(withJSONObject: cpu)).flatMap { String(data: $0, encoding: .utf8) }
        profile.topSelf = Self.topSelf(cpu)
        return profile
    }

    /// The 15 functions with the most self time in a V8 CPU profile, idle and program left out.
    nonisolated static func topSelf(_ profile: [String: Any]) -> [(name: String, ms: Double)] {
        let nodes = profile["nodes"] as? [[String: Any]] ?? []
        let samples = profile["samples"] as? [Int] ?? []
        let deltas = profile["timeDeltas"] as? [Int] ?? []
        var names: [Int: String] = [:]
        for node in nodes {
            guard let id = node["id"] as? Int, let frame = node["callFrame"] as? [String: Any] else { continue }
            let function = (frame["functionName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(anonymous)"
            let url = ((frame["url"] as? String) ?? "").split(separator: "/").last.map(String.init) ?? ""
            names[id] = "\(function) \(url):\(((frame["lineNumber"] as? Int) ?? 0) + 1)"
        }
        var selfMicros: [String: Int] = [:]
        for (sample, delta) in zip(samples, deltas) { selfMicros[names[sample] ?? "?", default: 0] += delta }
        return selfMicros.filter { !$0.key.hasPrefix("(idle)") && !$0.key.hasPrefix("(program)") }
            .sorted { $0.value > $1.value }.prefix(15).map { ($0.key, (Double($0.value) / 100).rounded() / 10) }
    }
}

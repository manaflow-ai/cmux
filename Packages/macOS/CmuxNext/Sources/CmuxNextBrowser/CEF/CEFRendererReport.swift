public import Foundation
import CmuxNextWakeups

/// Who owns a live Chromium page, as the app knows it: a browser tab, or the agent tab whose pane
/// shows the page. `renderers.list` reports it beside the page.
public nonisolated struct CEFRendererOwner: Sendable, Encodable, Equatable {
    /// `browser` or `agent`.
    public var kind: String
    public var tab: String
    public var tabTitle: String?
    public var pane: String?
    public var machine: String?
    public var workspace: String?
    public var workspaceTitle: String?
    /// The agent tab's acpmux session.
    public var session: String?

    public init(kind: String, tab: String) {
        self.kind = kind
        self.tab = tab
    }
}

/// `renderers.list` (`cmux app renderers`): every live Chromium page with its owner, and every
/// renderer helper process with its CPU and footprint. Raw facts: the CLI joins them into one
/// row per pid (cmux-tui `cli/app/renderers.rs`), so a busy `cmux Helper (Renderer)` pid names
/// its page, tab and agent session.
public nonisolated struct CEFRendererReport: Sendable, Encodable {
    public nonisolated struct Page: Sendable, Encodable {
        public var browser: Int32
        public var url: String
        public var title: String
        public var hidden: Bool
        public var rendererClients: [Int32]
        public var owner: CEFRendererOwner?
    }

    public nonisolated struct Helper: Sendable, Encodable {
        public var pid: Int32
        /// The `--renderer-client-id` its pages name; nil for an extension's renderer.
        public var client: Int32?
        public var isExtension: Bool
        public var memoryBytes: UInt64?
        /// Percent of one core over the interval, rounded to 0.1; nil without an interval.
        public var cpuPercent: Double?

        enum CodingKeys: String, CodingKey {
            case pid, client, memoryBytes, cpuPercent
            case isExtension = "extension"
        }
    }

    public var intervalMs: Int
    public var pages: [Page]
    public var helpers: [Helper]

    /// The wire form: snake_case keys.
    public static func encoded(_ report: CEFRendererReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(report)
    }
}

extension CEFEngine {
    /// The live pages (read now, on the main actor) and the renderer helpers, sampled twice
    /// `intervalMs` apart off the main actor for CPU (once when it is 0). Computed only when
    /// asked: no observer and no timer beyond the one wait.
    public func rendererReport(owners: [Int32: CEFRendererOwner], intervalMs: Int) async -> CEFRendererReport {
        let pages = rendererPages.map { page in
            CEFRendererReport.Page(browser: page.browserID, url: page.url, title: page.title, hidden: page.hidden,
                                   rendererClients: page.rendererClients, owner: owners[page.browserID])
        }
        let first = await Self.sampleRenderers(nil)
        var second: [Int32: ProcessUsage] = [:]
        if intervalMs > 0 {
            await Self.waitOnce(.milliseconds(intervalMs))
            for sampled in await Self.sampleRenderers(first.map(\.helper.pid)) { second[sampled.helper.pid] = sampled.usage }
        }
        let helpers = first.map { sampled in
            var out = sampled.helper
            let after = second[out.pid]
            out.memoryBytes = (after ?? sampled.usage)?.physFootprint
            if let before = sampled.usage, let after { out.cpuPercent = (after.cpuShare(since: before) * 1000).rounded() / 10 }
            return out
        }
        return CEFRendererReport(intervalMs: intervalMs, pages: pages, helpers: helpers)
    }

    /// This app's renderer helpers (or just `pids` again, for the second sample) and their counters.
    @concurrent
    private static func sampleRenderers(_ pids: [Int32]?) async -> [(helper: CEFRendererReport.Helper, usage: ProcessUsage?)] {
        let helpers: [CEFRendererReport.Helper] = pids?.map { CEFRendererReport.Helper(pid: $0, isExtension: false) }
            ?? ChromiumHelperProcess.list().compactMap { helper in
                switch helper.kind {
                case .renderer(let client): CEFRendererReport.Helper(pid: helper.pid, client: client, isExtension: false)
                case .extensionRenderer: CEFRendererReport.Helper(pid: helper.pid, isExtension: true)
                case .gpu, .network, .utility, .other: nil
                }
            }
        return helpers.map { ($0, ProcessUsage.sample($0.pid)) }
    }

    /// One wait between the samples: a one-shot deadline, not a sleep.
    private static func waitOnce(_ delay: Duration) async {
        let timer = DemandTimer(owner: "CEF.rendererReport")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            timer.schedule(after: delay) { continuation.resume() }
        }
        _ = timer
    }
}

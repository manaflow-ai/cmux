import Darwin
import Foundation
import Testing
import WebKit

@testable import CmuxBrowser

/// What each session world costs a tab: every session that drives a tab
/// runs its own page agent in every frame of every document the tab loads.
/// Measures, with real WebKit and the repository's page agent, how long a
/// reload takes and how much memory the web content process holds with
/// 0 to 8 session worlds, and whether ended sessions' worlds are given
/// back. The numbers set ``BrowserReplTabSessionLimit/standard`` and are
/// in docs/browser-repl/performance.md (Agent worlds).
///
///   CMUX_BREPL_WORLD_COST=1 swift test --package-path Packages/macOS/CmuxBrowser --filter BrowserReplSessionWorldCostTests
@MainActor
@Suite("Session world cost", .serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_BREPL_WORLD_COST"] == "1"))
struct BrowserReplSessionWorldCostTests {
    private static let presence = "cmuxReplAgent"
    private static let reloads = 7

    /// A main document with `frames` same-site iframes, each with a form,
    /// a list and some text, as a light real page has.
    private final class Pages: NSObject, WKURLSchemeHandler {
        let frames: Int
        init(frames: Int) { self.frames = frames }

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            guard let url = task.request.url else { return }
            let body = (0..<40).map { "<li><a href=#\($0)>item \($0)</a> <button>act \($0)</button></li>" }.joined()
            let html = url.path == "/" || url.path.isEmpty
                ? "<h1>main</h1><ul>\(body)</ul>" + (0..<frames).map { "<iframe src=\"/child\($0)\" width=200 height=100></iframe>" }.joined()
                : "<form><input name=q><select><option>a<option>b</select></form><ul>\(body)</ul>"
            task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: -1, textEncodingName: "utf-8"))
            task.didReceive(Data(html.utf8))
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
    }

    private final class Loads: NSObject, WKNavigationDelegate {
        var waiter: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            waiter?.resume()
            waiter = nil
        }
    }

    private struct Sample {
        let worlds: Int
        let reloadMs: Double
        let footprintMB: Double
    }

    private static func footprintMB(of webView: WKWebView) -> Double {
        guard let pid = (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else { return -1 }
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : -1
    }

    private static func load(_ webView: WKWebView, _ loads: Loads, _ start: () -> Void) async -> Double {
        let clock = ContinuousClock()
        let began = clock.now
        await withCheckedContinuation { continuation in
            loads.waiter = continuation
            start()
        }
        let elapsed = clock.now - began
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// Agents present in every frame, per world, after a load.
    private static func agentsPresent(_ webView: WKWebView, worlds: [BrowserReplSessionWorld]) async -> Bool {
        let frames = await BrowserReplFrame.readTree(of: webView)
        for world in worlds {
            for frame in frames {
                let present = try? await webView.callAsyncJavaScript(
                    #"return globalThis[Symbol.for("cmux.browserRepl.agent")] !== undefined;"#,
                    arguments: [:], in: frame.info, contentWorld: world.agent
                ) as? Bool
                if present != true { return false }
            }
        }
        return true
    }

    private static func measure(worlds count: Int, frames: Int, source: String) async throws -> Sample {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(Pages(frames: frames), forURLScheme: "cmux-cost")
        let worlds = (0..<count).map { _ in BrowserReplSessionWorld() }
        let installers = worlds.map { _ in BrowserReplAgentUserScript() }
        for (installer, world) in zip(installers, worlds) {
            installer.install(source: source, presenceHandlerName: presence, world: world.agent, in: configuration.userContentController)
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        let loads = Loads()
        webView.navigationDelegate = loads
        _ = await load(webView, loads) { webView.load(URLRequest(url: URL(string: "cmux-cost://site.test/")!)) }
        let present = await agentsPresent(webView, worlds: worlds)
        try #require(present, "a session's agent is missing from a frame")
        var times: [Double] = []
        for _ in 0..<reloads {
            times.append(await load(webView, loads) { webView.reload() })
        }
        let footprint = footprintMB(of: webView)
        for installer in installers { installer.release() }
        return Sample(worlds: count, reloadMs: median(times), footprintMB: footprint)
    }

    @Test func reloadTimeAndMemoryPerSessionWorld() async throws {
        let source = try #require(try browserReplRepositoryBundle().agentInstallSource)
        for frames in [0, 10] {
            var lines = ["frames=\(frames) (\(frames + 1) documents a load)", "worlds  reload p50 ms  web process footprint MB"]
            for count in [0, 1, 2, 4, 6, 8] {
                let sample = try await Self.measure(worlds: count, frames: frames, source: source)
                lines.append(String(format: "%6d  %13.1f  %25.1f", sample.worlds, sample.reloadMs, sample.footprintMB))
            }
            print("SESSION-WORLD-COST\n" + lines.joined(separator: "\n"))
        }
    }

    /// Sessions that come and go on one tab: each gets a fresh world, so
    /// the footprint must not grow with every session that ended faster
    /// than when every session reused one world (the control).
    @Test func endedSessionsWorldsAreGivenBack() async throws {
        let source = try #require(try browserReplRepositoryBundle().agentInstallSource)
        let shared = BrowserReplSessionWorld()
        for fresh in [true, false] {
            let configuration = WKWebViewConfiguration()
            configuration.setURLSchemeHandler(Pages(frames: 10), forURLScheme: "cmux-cost")
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
            let controller = webView.configuration.userContentController
            let loads = Loads()
            webView.navigationDelegate = loads
            _ = await Self.load(webView, loads) { webView.load(URLRequest(url: URL(string: "cmux-cost://site.test/")!)) }
            var lines = ["sessions ended  footprint MB (\(fresh ? "a fresh world each" : "one world reused, the control"), 11 documents)"]
            for round in 0..<120 {
                let world = fresh ? BrowserReplSessionWorld() : shared
                let installer = BrowserReplAgentUserScript()
                installer.install(source: source, presenceHandlerName: Self.presence, world: world.agent, in: controller)
                _ = await Self.load(webView, loads) { webView.reload() }
                if round == 0 {
                    let present = await Self.agentsPresent(webView, worlds: [world])
                    try #require(present, "the session's agent is missing from a frame")
                }
                if round % 20 == 0 || round == 119 {
                    lines.append(String(format: "%14d  %12.1f", round, Self.footprintMB(of: webView)))
                }
                installer.release()
            }
            _ = await Self.load(webView, loads) { webView.reload() }
            lines.append(String(format: "%14@  %12.1f", "none attached", Self.footprintMB(of: webView)))
            print("SESSION-WORLD-CHURN\n" + lines.joined(separator: "\n"))
        }
    }
}

import AppKit
import Darwin
import Foundation
import Testing
import WebKit
@testable import CmuxNextAgentPane

private actor BenchHost: AgentPaneHostProviding {
    let url: URL
    init(url: URL) { self.url = url }
    func handshake(sessionId: String?) async throws -> AgentPaneHandshake {
        .acpmux(AcpmuxConnection(url: url, dashboardToken: "bench", localAppToken: String(repeating: "0b", count: 32)), sessionId: sessionId)
    }
}

/// Frame latency through the real host transport against today's page-world WebSocket
/// (CMUX_PANE_TRANSPORT_BENCH=1; scripts/measure/pane-native-transport.sh). Each frame is about
/// 300 bytes of `session/update`; the page parses it and acknowledges it at once with an
/// allowlisted notification, so every number is a round trip through the whole path (the host's
/// allowlist check included). Workloads: `light`, 300 frames at 100 frames/s (no load); `paced`,
/// 2,000 frames at 2,000 frames/s; `burst`, 2,000 frames back to back. Main-thread CPU is the host main thread's CPU time across the burst.
/// CMUX_PANE_TRANSPORT_BENCH_VISIBLE=1 puts the windows on screen (a live Mac).
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_PANE_TRANSPORT_BENCH"] == "1"))
struct AgentPaneTransportBench {
    nonisolated static let rounds = Int(ProcessInfo.processInfo.environment["CMUX_PANE_TRANSPORT_BENCH_ROUNDS"] ?? "") ?? 5
    static let visible = ProcessInfo.processInfo.environment["CMUX_PANE_TRANSPORT_BENCH_VISIBLE"] == "1"

    /// The page of the host modes: the same bridge calls as bridgeSocket.ts, without React.
    static let nativePage = #"""
    <!doctype html><html><body>bench<script>
    const post = (method, params = {}) => window.webkit.messageHandlers.agentSession
      .postMessage({ id: String(Math.random()), method, params })
      .then((r) => { if (!r.ok) throw new Error(r.error && r.error.code); return r.value; });
    let connection, out = [], queued = false, ready = null;
    const send = (text) => {
      out.push(text);
      if (queued) return;
      queued = true;
      queueMicrotask(() => { queued = false; const frames = out; out = []; post("transport.send", { connection, frames }); });
    };
    const ack = (s) => send('{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"a' + s + '"}}');
    window.cmuxAcpmuxTransport = { receive(event) {
      for (const text of event.frames || []) {
        const m = JSON.parse(text);
        if (m.params && m.params.s !== undefined) ack(m.params.s);
        else if (m.id === 0 && ready) { const r = ready; ready = null; r(); }
      }
    } };
    window.startBench = async () => {
      await post("ready");
      connection = (await post("transport.open")).connection;
      await new Promise((r) => { ready = r; send(JSON.stringify({ jsonrpc: "2.0", id: 0, method: "initialize", params: {} })); });
      return connection;
    };
    </script></body></html>
    """#

    /// Today's page: the page world opens the socket (`direct`).
    static let directPage = #"""
    <!doctype html><html><body>bench<script>
    window.startBench = (url) => new Promise((resolve, reject) => {
      const ws = new WebSocket(url);
      ws.onopen = () => ws.send(JSON.stringify({ jsonrpc: "2.0", id: 0, method: "initialize", params: {} }));
      ws.onerror = () => reject(new Error("socket"));
      ws.onmessage = (event) => {
        const m = JSON.parse(event.data);
        if (m.params && m.params.s !== undefined) ws.send('{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"a' + m.params.s + '"}}');
        else if (m.id === 0) resolve(true);
      };
    });
    </script></body></html>
    """#

    enum Mode: String, CaseIterable {
        case direct
        /// The production pacer: next turn when idle, then one bridge call per display frame.
        case hostFrames = "host-frames"
        /// Every flush on the next main-loop turn (no display pacing), for comparison.
        case hostTurns = "host-turns"
    }

    final class Loaded: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    struct Rig {
        var mode: Mode
        var window: NSWindow
        var webView: WKWebView
        var pane: AgentPaneView?
        var connectionIndex: Int
    }

    /// The real pane is on screen; the bench windows are not. Turn off WebKit's hidden-page
    /// suppression where the SPI exists (bench only), or the hidden page stalls after a while.
    static func keepAwake(_ webView: WKWebView) -> Bool {
        var applied = false
        let preferences = webView.configuration.preferences
        for key in ["pageVisibilityBasedProcessSuppressionEnabled", "hiddenPageDOMTimerThrottlingEnabled"]
        where preferences.responds(to: NSSelectorFromString("_set\(key.prefix(1).uppercased())\(key.dropFirst()):")) {
            preferences.setValue(false, forKey: key)
            applied = true
        }
        return applied
    }

    static func pct(_ values: [UInt64], _ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        return Double(sorted[min(sorted.count - 1, max(0, Int((Double(sorted.count) * p).rounded(.up)) - 1))]) / 1e6
    }

    func window(_ index: Int) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 40 + 40 * index, y: 40 + 40 * index, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if Self.visible {
            NSApplication.shared.setActivationPolicy(.accessory)
            window.orderFrontRegardless()
        }
        return window
    }

    func rig(_ mode: Mode, index: Int, server: AcpmuxStandInServer) async throws -> Rig {
        let window = window(index)
        let before = server.peers.count
        switch mode {
        case .direct:
            let webView = WKWebView(frame: window.contentView!.bounds)
            print("PANE-STAGE awake \(Self.keepAwake(webView))")
            window.contentView!.addSubview(webView)
            let loaded = Loaded()
            webView.navigationDelegate = loaded
            await withCheckedContinuation { continuation in
                loaded.done = continuation
                webView.loadHTMLString(Self.directPage, baseURL: URL(string: "http://localhost/"))
            }
            _ = try await webView.callAsyncJavaScript("return await startBench(url)", arguments: ["url": server.url.absoluteString],
                                                      in: nil, contentWorld: .page)
            return Rig(mode: mode, window: window, webView: webView, pane: nil, connectionIndex: before)
        case .hostFrames, .hostTurns:
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pane-bench-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let page = directory.appendingPathComponent("index.html")
            try Self.nativePage.write(to: page, atomically: true, encoding: .utf8)
            let model = AgentPaneModel(host: BenchHost(url: server.url))
            let pane = try #require(AgentPaneView(model: model, source: .bundled(page)))
            pane.frame = window.contentView!.bounds
            print("PANE-STAGE awake \(Self.keepAwake(pane.webView))")
            window.contentView!.addSubview(pane)
            if mode == .hostTurns { model.transport.pacer = AgentPaneNextTurnPacer() }
            // The page loads on its own; wait for it, then start.
            let deadline = ContinuousClock.now + .seconds(20)
            while ContinuousClock.now < deadline {
                if (try? await pane.webView.evaluateJavaScript("typeof startBench") as? String) == "function" { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            _ = try await pane.webView.callAsyncJavaScript("return await startBench()", arguments: [:], in: nil, contentWorld: .page)
            return Rig(mode: mode, window: window, webView: pane.webView, pane: pane, connectionIndex: before)
        }
    }

    @Test func framesThroughTheHostAgainstThePageSocket() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        var rigs: [Rig] = []
        for (index, mode) in Mode.allCases.enumerated() {
            print("PANE-STAGE rig \(mode.rawValue)")
            let rig = try await rig(mode, index: index, server: server)
            print("PANE-STAGE warm \(mode.rawValue) connection=\(rig.connectionIndex)")
            _ = await server.stream(to: rig.connectionIndex, count: 500) // warm up
            rigs.append(rig)
        }
        defer { for rig in rigs { rig.pane?.close(); rig.window.close() } }
        var light: [Mode: [UInt64]] = [:], paced: [Mode: [UInt64]] = [:], burst: [Mode: [UInt64]] = [:], totals: [Mode: [UInt64]] = [:]
        var cpu: [Mode: [UInt64]] = [:], flushes: [Mode: [Int]] = [:]
        for round in 0..<Self.rounds {
            for offset in 0..<rigs.count {
                let rig = rigs[(round + offset) % rigs.count]
                print("PANE-STAGE round \(round) \(rig.mode.rawValue)")
                // 300 frames at 100 frames/s: ordinary token streaming, no load.
                let lightRun = await server.stream(to: rig.connectionIndex, count: 300, interval: 10_000_000)
                light[rig.mode, default: []] += lightRun.latencies
                let pacedRun = await server.stream(to: rig.connectionIndex, count: 2000, interval: 500_000)
                paced[rig.mode, default: []] += pacedRun.latencies
                let flushed = rig.pane?.model.transport.flushes ?? 0
                let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                print("PANE-STAGE paced done \(rig.mode.rawValue)")
                let result = await server.stream(to: rig.connectionIndex, count: 2000)
                print("PANE-STAGE burst done \(rig.mode.rawValue) total_ms=\(Double(result.total) / 1e6)")
                cpu[rig.mode, default: []].append(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- cpu0)
                burst[rig.mode, default: []] += result.latencies
                totals[rig.mode, default: []].append(result.total)
                flushes[rig.mode, default: []].append((rig.pane?.model.transport.flushes ?? 0) - flushed)
            }
        }
        var rows: [[String: Any]] = []
        for mode in Mode.allCases {
            let d = Mode.direct
            var row: [String: Any] = ["mode": mode.rawValue, "rounds": Self.rounds, "visible": Self.visible]
            for (name, values, base) in [("light", light[mode]!, light[d]!), ("paced", paced[mode]!, paced[d]!),
                                         ("burst", burst[mode]!, burst[d]!)] {
                for p in [0.5, 0.95, 0.99] {
                    let key = "\(name)_p\(Int(p * 100))_ms"
                    row[key] = Self.pct(values, p)
                    row["\(name)_overhead_p\(Int(p * 100))_ms"] = Self.pct(values, p) - Self.pct(base, p)
                }
            }
            row["burst_total_median_ms"] = Self.pct(totals[mode]!, 0.5)
            row["burst_total_overhead_ms"] = Self.pct(totals[mode]!, 0.5) - Self.pct(totals[d]!, 0.5)
            row["main_cpu_median_ms"] = Self.pct(cpu[mode]!, 0.5)
            row["bridge_calls_per_burst_median"] = flushes[mode]!.sorted()[flushes[mode]!.count / 2]
            rows.append(row)
            let json = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            print("PANE-BENCH " + String(decoding: json, as: UTF8.self))
        }
    }
}

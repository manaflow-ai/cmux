import AppKit
import Darwin
import WebKit

/// Starts WebKit for the agent pages at the top of launch (cx-z9kz0): its
/// first-use setup and the shared pool's first web content process then run
/// while the windows build, so the first agent page loads sooner (live
/// about 65 ms earlier on a cold launch). The empty page goes once an agent
/// page has loaded or the launch settled (`LaunchSettle`).
public enum AgentPaneWarmup {
    private static var view: WKWebView?
    /// probe4 (to drop): one in-memory store for every agent page, so the prewarmed process fits the first.
    static let dataStore = WKWebsiteDataStore.nonPersistent()
    private static let diagDelegate = WarmupDiagDelegate() // diag (to drop)

    public static func start() {
        guard view == nil else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.processPool = AgentPaneView.processPool
        // diag (to drop): load the real page here to see how early it can be live.
        let source = AgentPaneView.bundledPage.map { AgentPaneSource.bundled($0) }
        configuration.userContentController.addUserScript(WKUserScript(source: """
        window.__cmuxT = {docStart: performance.now()};
        document.addEventListener('DOMContentLoaded', () => { window.__cmuxT.dcl = performance.now();
          requestAnimationFrame(() => { window.__cmuxT.raf1 = performance.now(); }); });
        new PerformanceObserver((list) => { for (const e of list.getEntries()) window.__cmuxT[e.name] = e.startTime; }).observe({type: 'paint', buffered: true});
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        view.navigationDelegate = diagDelegate
        AgentPaneLaunchTimings.shared.mark("diag.warm.load")
        _ = source
        view.loadHTMLString("<!doctype html><title></title>", baseURL: nil)
        // probe4 (to drop): a prewarmed web process (initialized, no page) for the first agent page.
        let warm = NSSelectorFromString("_warmInitialProcess")
        if AgentPaneView.processPool.responds(to: warm) {
            _ = AgentPaneView.processPool.perform(warm)
            AgentPaneLaunchTimings.shared.mark("diag.warm.prewarmed")
        }
        self.view = view
        WebKitProcessProbe.start()
    }

    public static func finish() {
        view = nil
    }
}

/// diag (to drop): the warm-up page's navigation and page timings, as `diag.warm.*` marks.
private final class WarmupDiagDelegate: NSObject, WKNavigationDelegate {
    var finished = false
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        AgentPaneLaunchTimings.shared.mark("diag.warm.nav_start")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        AgentPaneLaunchTimings.shared.mark("diag.warm.nav_commit")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        AgentPaneLaunchTimings.shared.mark("diag.warm.page_loaded")
        finished = true
        webView.callAsyncJavaScript("await new Promise(r => setTimeout(r, 300)); const t = window.__cmuxT || {}; return JSON.stringify(Object.entries(t).map(([k, v]) => [k, performance.timeOrigin + v]));", arguments: [:], in: nil, in: .page) { result in
            guard case .success(let value) = result, let text = value as? String, let data = text.data(using: .utf8),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else { return }
            for row in rows where row.count == 2 {
                guard let name = row[0] as? String, let at = row[1] as? Double else { continue }
                AgentPaneLaunchTimings.shared.mark("diag.warm.t.\(name)@\(at)")
            }
        }
    }
}

/// probe2 (to drop): when WebKit's processes start and go idle, and how long the main queue keeps
/// a block waiting, from background threads, as `diag.wk.*` and `diag.mq.*` marks with their time.
nonisolated private final class ProbeRows: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ row: String) { lock.lock(); items.append(row); lock.unlock() }
    func all() -> [String] { lock.lock(); defer { lock.unlock() }; return items }
}

private enum WebKitProcessProbe {
    nonisolated static func post(_ rows: [String]) {
        Task { @MainActor in for row in rows { AgentPaneLaunchTimings.shared.mark(row) } }
    }

    static func start() {
        let begin = Date().timeIntervalSince1970
        let deadline = begin + 0.9
        let pinger = Thread {
            let rows = ProbeRows()
            while Date().timeIntervalSince1970 < deadline {
                let sent = Date().timeIntervalSince1970
                DispatchQueue.main.async {
                    let got = Date().timeIntervalSince1970
                    rows.add("diag.mq.\(Int((sent - begin) * 1000))=\(Int((got - sent) * 1000))@\(got * 1000)")
                }
                usleep(5000)
            }
            usleep(400_000)
            WebKitProcessProbe.post(rows.all())
        }
        pinger.start()
        let watcher = Thread {
            var seen: [pid_t: (name: String, start: Double, cpu: UInt64, changes: [Double])] = [:]
            while Date().timeIntervalSince1970 < deadline {
                let now = Date().timeIntervalSince1970
                var pids = [pid_t](repeating: 0, count: 8192)
                let count = pids.withUnsafeMutableBufferPointer { proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size)) }
                for pid in pids.prefix(Int(max(0, count))) where pid > 0 {
                    var info = proc_bsdinfo()
                    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { continue }
                    let started = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6
                    guard started >= begin - 0.1 else { continue }
                    let name = withUnsafeBytes(of: info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                    guard name.hasPrefix("com.apple.WebKit") else { continue }
                    var usage = rusage_info_v2()
                    let ok = withUnsafeMutablePointer(to: &usage) {
                        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
                    }
                    let cpu = ok == 0 ? usage.ri_user_time + usage.ri_system_time : 0
                    if var old = seen[pid] {
                        if cpu != old.cpu { old.cpu = cpu; old.changes.append(now); seen[pid] = old }
                    } else {
                        seen[pid] = (String(name.dropFirst("com.apple.WebKit.".count)), started, cpu, [now])
                    }
                }
                usleep(2000)
            }
            var rows: [String] = []
            for (index, entry) in seen.values.sorted(by: { $0.start < $1.start }).enumerated() {
                let label = "diag.wk.\(index).\(entry.name)"
                rows.append("\(label).start@\(entry.start * 1000)")
                // Every quiet stretch (no CPU for 10 ms): the process waits.
                for (n, quiet) in zip(entry.changes, entry.changes.dropFirst()).filter({ $1 - $0 > 0.010 }).prefix(12).enumerated() {
                    rows.append("\(label).idle\(n)@\(quiet.0 * 1000)")
                    rows.append("\(label).busy\(n)@\(quiet.1 * 1000)")
                }
            }
            WebKitProcessProbe.post(rows)
        }
        watcher.start()
    }
}

import AppKit
@testable import CmuxNextPages
import CmuxNextTestSupport
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing
import WebKit

/// The wakeups of a frozen WebKit page's WebContent process (`CMUX_PAGE_FREEZE_WAKEUPS=1`, live on a
/// Mac with a window server; p13-webui-028's test phase). A page with a 90 ms interval timer (about
/// 11 wakeups/s while it shows) is hidden in its window and frozen (``PageWebView/freezePage()``);
/// after WebKit's hidden-page throttling settles, its process wakes at most 0.2 times a second.
/// The counter is `ri_interrupt_wkups` (``ProcessUsage/interruptWakeups(of:)``), the one Chrome
/// reports as idle wakeups (base/process/process_metrics_apple.mm). With CMUX_PERF_RESULT_DIR both rates are
/// result-v1 (lab story swift-page-freeze-wakeups).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)),
       .enabled(if: ProcessInfo.processInfo.environment["CMUX_PAGE_FREEZE_WAKEUPS"] != nil))
struct PageFreezeWakeupsBenchmark {
    static let tickingPage = """
    <!doctype html><title>Ticking</title>
    <script>setInterval(() => { document.title = String(performance.now()); }, 90);</script>
    """
    /// The shown page's sample: enough to show the timer runs.
    static let shownWindow: Duration = .seconds(10)
    /// After the freeze, before the sample: WebKit's DOM timer throttle grows while the page stays hidden.
    static let settle: Duration = .seconds(20)
    /// The frozen page's sample, as p13-webui-029 measures (wakeups over 30 s).
    static let frozenWindow: Duration = .seconds(30)
    static let budgetPerSecond = 0.2

    @Test func aHiddenFrozenWebKitPageWakesAtMostOneFifthPerSecond() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-freeze-wakeups-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(Self.tickingPage.utf8).write(to: root.appendingPathComponent("index.html"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tab = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(tab)
        window.orderFrontRegardless()
        let descriptor = PageDescriptor(id: "test.page-freeze-wakeups", resource: "page-freeze-wakeups", processGroup: .viewer, namespaces: [])
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: nil, deadlines: .testing()))
        defer { view.close() }
        view.frame = tab.bounds
        tab.addSubview(view)
        await view.waitUntilLoaded()
        let pid = try #require(Self.webContentProcess(of: view.webView), "the page has a WebContent process")

        let shown = try await Self.wakeupsPerSecond(of: pid, over: Self.shownWindow)
        tab.isHidden = true
        #expect(view.freezePage())
        try await Task.sleep(for: Self.settle)
        let frozen = try await Self.wakeupsPerSecond(of: pid, over: Self.frozenWindow)
        if let results = try PerfResultWriter() {
            try results.record("swift.page_freeze.shown_wakeups", unit: .perSecond, samples: [shown])
            try results.record("swift.page_freeze.frozen_wakeups", unit: .perSecond, samples: [frozen])
        }
        print("PAGE_FREEZE_WAKEUPS shown_per_s=\(shown) frozen_per_s=\(frozen) budget_per_s=\(Self.budgetPerSecond)")
        #expect(shown > 5, "the timer runs while the page shows")
        #expect(frozen <= Self.budgetPerSecond)
    }

    /// The WebContent process of `webView` (`_webProcessIdentifier`, WebKit SPI); nil before the
    /// first load or after it ended.
    private static func webContentProcess(of webView: WKWebView) -> pid_t? {
        guard webView.responds(to: NSSelectorFromString("_webProcessIdentifier")),
              let pid = (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return pid
    }

    private static func wakeupsPerSecond(of pid: pid_t, over window: Duration) async throws -> Double {
        let clock = ContinuousClock()
        let start = clock.now
        let first = try #require(ProcessUsage.interruptWakeups(of: pid))
        try await Task.sleep(for: window)
        let last = try #require(ProcessUsage.interruptWakeups(of: pid))
        let elapsed = clock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return Double(last &- first) / seconds
    }
}

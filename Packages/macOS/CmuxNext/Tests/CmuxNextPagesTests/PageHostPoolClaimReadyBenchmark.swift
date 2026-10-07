import AppKit
import CmuxNextSettings
@testable import CmuxNextPages
import Foundation
import Testing
import WebKit

/// Claim-to-ready of a Settings page from the parked spare (`CMUX_PAGE_CLAIM_BENCH=<runs>`).
///
/// Ready: the claimed document shows settings rows (`[data-row-key]` under `.content h1`) and no
/// read-only banner, after its reads went through the claim's routes. The page records the moment on
/// its own clock (`performance.timeOrigin + now`, wall-clock milliseconds), so the coarse host poll
/// that reads it adds nothing to the number.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(10)),
       .enabled(if: ProcessInfo.processInfo.environment["CMUX_PAGE_CLAIM_BENCH"] != nil))
struct PageHostPoolClaimReadyBenchmark {
    static let readyProbe = """
    (() => {
      const root = document.documentElement;
      const check = () => {
        if (root.dataset.benchReady) return true;
        if (document.querySelector('[data-read-only]')) return false;
        if (!document.querySelector('.content h1') || !document.querySelector('[data-row-key]')) return false;
        root.dataset.benchReady = String(performance.timeOrigin + performance.now());
        return true;
      };
      if (check()) return;
      const observer = new MutationObserver(() => { if (check()) observer.disconnect(); });
      observer.observe(root, { subtree: true, childList: true, attributes: true });
    })();
    """

    @Test func claimToReady() async throws {
        let runs = Int(ProcessInfo.processInfo.environment["CMUX_PAGE_CLAIM_BENCH"] ?? "") ?? 8
        var samples: [Double] = []
        for _ in 0..<max(runs, 1) {
            if let sample = try await Self.oneClaim() { samples.append(sample) }
        }
        samples.sort()
        let median = samples.isEmpty ? .nan : samples[samples.count / 2]
        print("PAGE_CLAIM_BENCH runs=\(samples.count) median_ms=\(median) samples_ms=\(samples.map { Int($0.rounded()) })")
        #expect(samples.count == max(runs, 1))
    }

    private static func oneClaim() async throws -> Double? {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var policy = PageHostPool.Policy()
        policy.idleInput = .milliseconds(5)
        let pool = PageHostPool(policy: policy, activity: { 0 }, isTrackingMenu: { false })
        defer { pool.dropSpare(); pool.claimedHosts.forEach(pool.release) }
        pool.follow(window)
        pool.noteLikely()
        if !pool.isSpareReady {
            _ = await PageTestWait.value("spare ready") { (done: @escaping (Bool) -> Void) in
                pool.onSpareReady = { _ in done(true) }
            }
        }
        // A parked spare waits seconds or more in the app: let its document settle first.
        try await Task.sleep(for: .seconds(1))
        let provider = PageHostPoolSettingsClaimTests.RecordingProvider()
        let routes = [PageRoute(prefix: "cmux.settings.", provider: provider)]
        let start = Date().timeIntervalSince1970 * 1_000
        let page = try #require(pool.claim(.settings, routes: routes, route: "#/settings/general",
                                           window: window, focus: false))
        // The probe covers the current document and any document the claim loads next.
        page.webKitView.configuration.userContentController.addUserScript(
            WKUserScript(source: readyProbe, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        page.webKitView.evaluateJavaScript(readyProbe, completionHandler: nil)
        if let content = window.contentView {
            page.frame = content.bounds
            content.addSubview(page)
        }
        for _ in 0..<400 {
            let ready = try? await page.webKitView.callAsyncJavaScript(
                "return document.documentElement.dataset.benchReady || null;", contentWorld: .page) as? String
            if let ready, let at = Double(ready) { return at - start }
            try await Task.sleep(for: .milliseconds(25))
        }
        let text = try? await page.webKitView.callAsyncJavaScript(
            "return (document.body && document.body.innerText || '').slice(0, 300);", contentWorld: .page) as? String
        Issue.record("claimed page never became ready; ops \(provider.ops); text \(text ?? "nil")")
        return nil
    }
}

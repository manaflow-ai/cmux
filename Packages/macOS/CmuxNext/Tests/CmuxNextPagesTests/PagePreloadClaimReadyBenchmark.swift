import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextInputCoreTestSupport
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSettings
import CmuxNextTestSupport
import CmuxNextWakeups
import Foundation
import Testing
import WebKit

/// Claim-to-ready of a Settings page from the preload slot (`CMUX_PAGE_CLAIM_BENCH=<runs>`), the app's
/// path since p13-webui-045 retired PageHostPool: the open names Settings, ``PagePreloads`` loads it
/// parked in a shown window, and the next open claims it with its routes (``PagePreloads/claim(_:routes:route:documentAttributes:surface:dynamicResources:)``).
///
/// Ready: the claimed document shows settings rows with enabled controls (a row enables its controls
/// only after the owner's values arrive through the claim's routes) and no read-only banner. The page records the moment on
/// its own clock (`Date.now()`, wall-clock milliseconds), so the coarse host poll
/// that reads it adds nothing to the number. With CMUX_PERF_RESULT_DIR every claim is result-v1 (lab story
/// swift-page-claim-ready).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(10)),
       .enabled(if: ProcessInfo.processInfo.environment["CMUX_PAGE_CLAIM_BENCH"] != nil))
struct PagePreloadClaimReadyBenchmark {
    static let readyProbe = """
    (() => {
      const root = document.documentElement;
      const check = () => {
        if (root.dataset.benchReady) return true;
        if (document.querySelector('[data-read-only]')) return false;
        // Every control stays disabled until the owner's values arrive (SettingRow).
        if (!document.querySelector('.content h1')) return false;
        if (!document.querySelector('[data-row-key] :is(button,input,select):not(:disabled)')) return false;
        root.dataset.benchReady = String(Date.now());
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
        var claims: [String] = []
        for _ in 0..<max(runs, 1) {
            if let sample = try await Self.oneClaim(claims: &claims) { samples.append(sample) }
        }
        if !samples.isEmpty { try PerfResultWriter()?.record("swift.page_claim.claim_to_ready", unit: .ms, samples: samples) }
        samples.sort()
        let median = samples.isEmpty ? .nan : samples[samples.count / 2]
        print("PAGE_CLAIM_BENCH runs=\(samples.count) median_ms=\(median) samples_ms=\(samples.map { Int($0.rounded()) }) claims=\(claims)")
        #expect(samples.count == max(runs, 1))
    }

    private static func oneClaim(claims: inout [String]) async throws -> Double? {
        let window = PagePreloadPageTests.shownWindow()
        defer { window.close() }
        let content = try #require(window.contentView)
        // The app's deadlines, which fire on their own: the slot's cover and park run as in the app.
        let deadlines = MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget()))
        let host = WebUIHost(chromium: nil, openPanel: nil, memory: QuietMemoryRegistry(), deadlines: deadlines)
        let slot = PagePreloadSlot(parkState: .renderedParked, deadlines: deadlines)
        host.preload = slot
        let preloads = PagePreloads(webUI: host, slot: slot, deadlines: deadlines, input: FakeInputTap(),
                                    isEnabled: { true }, target: { (content, content.bounds.size) })
        defer { preloads.drop() }
        // The first open names Settings (the slot is empty, so it opens cold elsewhere); then it preloads.
        #expect(preloads.claim(.settings, routes: []) == nil)
        preloads.preloadNow()
        for _ in 0..<400 where slot.phase != .parked {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard slot.phase == .parked else {
            Issue.record("the Settings preload never parked (phase \(slot.phase?.rawValue ?? "none"))")
            return nil
        }
        // A parked page waits seconds or more in the app: let its document settle first.
        try await Task.sleep(for: .seconds(1))
        let provider = RecordingPageProvider()
        let routes = [PageRoute(prefix: "cmux.settings.", provider: provider)]
        let start = Date().timeIntervalSince1970 * 1_000
        let page = try #require(preloads.claim(.settings, routes: routes, route: "#/settings/general", surface: .settings))
        defer { host.close(page) }
        // The probe covers the current document and any document the claim loads next.
        page.webView.configuration.userContentController.addUserScript(
            WKUserScript(source: readyProbe, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        page.webView.evaluateJavaScript(readyProbe, completionHandler: nil)
        page.frame = content.bounds
        content.addSubview(page)
        for _ in 0..<400 {
            let ready = try? await page.webView.callAsyncJavaScript(
                "return document.documentElement.dataset.benchReady || null;", contentWorld: .page) as? String
            if let ready, let at = Double(ready) {
                claims.append(page.lastClaimSummary)
                return at - start
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let text = try? await page.webView.callAsyncJavaScript(
            "return (document.body && document.body.innerText || '').slice(0, 300);", contentWorld: .page) as? String
        Issue.record("claimed page never became ready; ops \(provider.ops); text \(text ?? "nil")")
        return nil
    }
}

extension PageWebView {
    /// The claim outcome for the benchmark line (`acknowledged@1.2ms`); `-` when the build has none.
    var lastClaimSummary: String {
        lastClaim.map { "\($0.path.rawValue)@\(String(format: "%.1f", $0.milliseconds))ms" } ?? "-"
    }
}

#if os(iOS)
import Foundation
import Testing
@testable import CmuxMobileShellUI

/// The one-time What's New sheet gates its presentation on every web page's
/// load outcome, so `outcome()` must always settle: a load that could stay
/// `.loading` forever would silently suppress the notice for the whole
/// launch. Both failure paths here are deterministic (no live network): the
/// navigation allowlist cancels before any request, and the deadline fires
/// while the session exchange hangs.
@MainActor
@Suite struct MobileWhatsNewWebPageLoadTests {
    /// A session exchange that never resolves, standing in for a wedged
    /// network: only the load's own deadline can settle it.
    private struct HangingWebAppSession: MobileWebAppSessionProviding {
        func sessionCookies(for destination: URL) async -> [HTTPCookie]? {
            try? await Task.sleep(for: .seconds(3600))
            return nil
        }
    }

    @Test func offAllowlistURLSettlesFailed() async {
        let load = MobileWhatsNewWebPageLoad(
            url: URL(string: "https://not-allowlisted.example/whats-new")!,
            allowedHosts: ["cmux.com"],
            webAppSession: nil,
            // The main-frame policy rejection settles the load directly, so
            // this normally never waits; the deadline only bounds the test
            // if WebKit ever stops consulting the policy for the first load.
            deadline: .seconds(5)
        )
        #expect(await load.outcome() == .failed)
        #expect(load.phase == .failed)
    }

    @Test func deadlineSettlesFailedWhileSessionExchangeHangs() async {
        let load = MobileWhatsNewWebPageLoad(
            url: URL(string: "https://cmux.com/whats-new")!,
            allowedHosts: ["cmux.com"],
            webAppSession: HangingWebAppSession(),
            deadline: .milliseconds(50)
        )
        #expect(await load.outcome() == .failed)
    }

    @Test func settledOutcomeAnswersLateAwaitersImmediately() async {
        let load = MobileWhatsNewWebPageLoad(
            url: URL(string: "https://cmux.com/whats-new")!,
            allowedHosts: ["cmux.com"],
            webAppSession: HangingWebAppSession(),
            deadline: .milliseconds(50)
        )
        _ = await load.outcome()
        // A second await after settling must answer from the terminal phase
        // instead of parking a continuation that nothing will ever resume.
        #expect(await load.outcome() == .failed)
    }
}
#endif

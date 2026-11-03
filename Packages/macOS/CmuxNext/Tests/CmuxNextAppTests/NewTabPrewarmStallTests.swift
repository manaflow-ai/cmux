import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
import Foundation
import Testing

/// The New Tab spare's WebKit load must never hold the main thread at launch (cua-2 hangs,
/// 2026-10-14): on a host with a wedged sandboxd, `WKWebView.load` blocked in WebKit's
/// registerUserInstalledFonts / sandbox_extension_issue for more than 10 s, inside
/// `NewTabSparePool.prewarm()` before the first window. Here a stalled WebKit stands in: making
/// the spare blocks its thread for 2 s.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewTabPrewarmStallTests {
    @Test func launchPrewarmDoesNotWaitForAStalledWebKit() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-prewarm-stall")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let pool = services.newTabSpares
            pool.dropAll()
            var made = 0
            pool.makeSpare = { _ in
                made += 1
                Thread.sleep(forTimeInterval: 2) // WebKit's first load, wedged
                return nil
            }
            let start = ContinuousClock.now
            pool.prewarm()
            let held = ContinuousClock.now - start
            #expect(held < .milliseconds(100), "prewarm held the main thread for \(held) (made \(made))")
        }
    }

    /// sandboxd never answers: the pool makes no spare this run and the main thread stays free.
    @Test func aWedgedWebKitSetupGetsNoSpare() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-prewarm-wedged")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let pool = NewTabSparePool(services: services, memoryPressure: services.memoryPressure)
            var made = 0
            pool.makeSpare = { _ in
                made += 1
                return nil
            }
            pool.webKit.request = { Thread.sleep(forTimeInterval: 600) } // a wedged sandboxd
            pool.prewarm()
            pool.start()
            #expect(pool.webKit.state == .probing)
            // The main actor keeps turning while the probe hangs: this wait runs on it.
            try await Task.sleep(for: WebKitSetupGate.timeout + .milliseconds(500))
            #expect(pool.webKit.state == .slow)
            #expect(made == 0)
        }
    }
}

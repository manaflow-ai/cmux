import CmuxNextDesign
@testable import CmuxNextPages
import Foundation
import Testing
import WebKit

/// A page that shows in Chromium never binds WebKit's process pool (first-5s bench, 2026-10-28). The shared
/// `PageProcessPool.shared` is made on first use, and `-[WKProcessPool init]` then waits on notifyd
/// (`WebProcessPool::platformInitialize` -> `notify_get_state`): 2.7 s on the main thread right after Cmd-Shift-N on the
/// optimized v2.2.3, whose new window's New Tab page shows in Chromium and never makes a WebKit view. The pool is
/// bound when the page builds its WebKit engine (a WebKit page, or a Chromium page's fallback), as Chrome makes a
/// renderer's view only for a frame whose renderer it creates.
@MainActor @Suite struct PageProcessPoolBindingTests {
    static func handler() -> PageSchemeHandler {
        PageSchemeHandler(page: .settings, root: FileManager.default.temporaryDirectory, devServer: nil)
    }

    /// The configuration a page is made with names no process pool: building it does not make the shared pool.
    @Test func aPagesHostConfigurationBindsNoProcessPool() {
        let host = PageWebView.hostConfiguration(handler: Self.handler(), documentAttributes: [:], options: PageEngineOptions())
        // With none bound WebKit gives the configuration a fresh default pool when it is read.
        #expect(host.configuration.processPool !== PageProcessPool.shared,
                "a page's configuration bound the shared pool before any WebKit engine was built")
    }

    /// Its WebKit engine binds the shared pool, once, when it is built: WebKit pages still share their processes.
    @Test func theWebKitEngineBindsTheSharedPoolWhenBuilt() {
        let host = PageWebView.hostConfiguration(handler: Self.handler(), documentAttributes: [:], options: PageEngineOptions())
        let engine = PageWebKitEngine(recipe: PageWebKitRecipe(configuration: host.configuration, processGroup: nil, openPanel: nil))
        #expect(engine.view.configuration.processPool === PageProcessPool.shared)
    }
}

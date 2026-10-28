#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// `debug.webui`'s App half: the census reads the app's own page registry, the
/// Chromium spare window and the browser tabs. The CEFTab and CEFPageChromiumPage casts need a
/// live Chromium runtime, which no unit test has; the tagged-build run in the commit covers them.
@MainActor @Suite(.serialized)
struct DebugWebUIWiringTests {
    static func services() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }

    @Test func noServicesAnswersNoCensus() {
        #expect(AppControl.webUICensus(nil, reset: false) == nil)
    }

    @Test func theCensusReadsTheAppsPagesSpareWindowAndTabs() throws {
        let services = Self.services()
        let census = try #require(AppControl.webUICensus(services, reset: true))
        let report = census.report(helpers: [])
        let spares = try #require(report["spares"]?.arrayValue)
        let window = try #require(spares.first)
        #expect(window["spare"]?.stringValue == "cef_window")
        #expect(window["state"]?.stringValue == services.cache.cef.spareWindowState)
        #expect(window["renderer_clients"] == .array([]))
        #expect(report["browser_tabs"] == .array([]))
        #expect(report["pages"]?.arrayValue?.count == services.webUI.registry.pages().count)
        #expect(report["processes"] == .array([]))
    }

    /// The test process runs no Chromium helper: the argv listing finds none.
    @Test func theHelperListingFindsNoHelperOutsideTheApp() {
        #expect(AppControl.webUIHelpers(of: getpid()).isEmpty)
        #expect(AppControl.webUIHelpers(of: nil).isEmpty, "host mode with no host attached lists none")
    }
}
#endif

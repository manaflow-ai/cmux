#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextApp
import CmuxNextOracle
import Testing

/// The app's `windows` facet (p15-oracle-041): the app list provides it and reads the window manager's windows,
/// key and main from the windows it is given, and frames against AppKit's screens. Run:
/// `swift test --filter OracleWindowsAppFacetTests`.
@MainActor @Suite(.serialized) struct OracleWindowsAppFacetTests {
    @Test func theAppListProvidesTheFacet() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let facets = services.makeOracleFacets()
        #expect(facets.provided.contains(.windows))
        #expect(facets.signalsChanges(.windows))
        // No window open: an empty list, not an error.
        let result = try #require(try facets.beginCapture([.windows]).completed?["windows"])
        #expect(result == ["count": 0, "order": [], "key": nil, "main": nil, "list": []])
    }

    /// A screen frame the reading copies in points; the fractions come from it.
    @Test func theReadingCopiesTheScreens() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let reading = services.windows.oracleWindows(key: nil, main: nil, screens: NSScreen.screens)
        #expect(reading.windows.isEmpty)
        #expect(reading.screens.count == NSScreen.screens.count)
        if let first = NSScreen.screens.first, let copied = reading.screens.first {
            #expect(copied.frame.width == Double(first.frame.width))
            #expect(copied.visibleFrame.height == Double(first.visibleFrame.height))
        }
    }
}
#endif

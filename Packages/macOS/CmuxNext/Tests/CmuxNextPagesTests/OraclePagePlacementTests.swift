#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextPages
import Testing

/// Which pages the `webviews` facet asks and where it places them: a page is placed by the nearest
/// superview the place map knows (a page or agent tab's view); a page in no tab but in a window has no place; a page
/// in no tab and no window, and any page inside the New Tab spare, is left out. Run:
/// `swift test --filter OraclePagePlacementTests`.
@MainActor
struct OraclePagePlacementTests {
    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func aPageIsPlacedByTheTabViewThatHoldsIt() {
        let tab = NSView(), container = NSView(), page = NSView()
        tab.addSubview(container)
        container.addSubview(page)
        let places = [ObjectIdentifier(tab): OraclePagePlace(tab: "tab_1", pane: "pane_1")]
        let reached = WebUIHost.oracleReachable([page], places: places, spare: nil)
        #expect(reached.count == 1)
        #expect(reached.first?.page === page)
        #expect(reached.first?.place?.tab == "tab_1")
        #expect(reached.first?.place?.pane == "pane_1")
    }

    @Test func aWindowedPageHasNoPlaceAndAPageInNeitherIsLeftOut() {
        let window = Self.window()
        defer { window.close() }
        let windowed = NSView(), detached = NSView()
        window.contentView?.addSubview(windowed)
        let reached = WebUIHost.oracleReachable([detached, windowed], places: [:], spare: nil)
        #expect(reached.map { $0.page } == [windowed])
        #expect(reached.first?.place?.tab == nil)
    }

    @Test func aPageInsideTheNewTabSpareIsLeftOut() {
        let window = Self.window()
        defer { window.close() }
        let spare = NSView(), page = NSView(), other = NSView()
        window.contentView?.addSubview(spare)
        window.contentView?.addSubview(other)
        spare.addSubview(page)
        let places = [ObjectIdentifier(spare): OraclePagePlace(tab: "tab_spare", pane: "pane_1")]
        let reached = WebUIHost.oracleReachable([page, other], places: places, spare: spare)
        #expect(reached.map { $0.page } == [other])
    }
}
#endif

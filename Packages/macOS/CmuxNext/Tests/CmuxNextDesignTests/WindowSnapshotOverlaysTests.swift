import AppKit
@testable import CmuxNextDesign
import Testing

/// A window snapshot shows what the app draws over the window, as on screen: a context menu
/// (the window server lists it, AppKit's window list does not), a hover card panel and a
/// popover, cut to the snapshot's region. Other apps' windows, the app's own windows behind,
/// beside or invisible, the child windows the snapshot already composites and the app's other
/// ordinary windows in front with everything that belongs to them stay out, so a covered window
/// still comes out whole.
@Suite struct WindowSnapshotOverlaysTests {
    private let pid: pid_t = 4242
    /// The snapshot's region in window server coordinates (top-left origin).
    private let region = CGRect(x: 100, y: 100, width: 800, height: 600)

    private func listed(_ number: Int, pid: pid_t? = nil, layer: Int = 0, bounds: CGRect = CGRect(x: 300, y: 300, width: 200, height: 150),
                        alpha: Double = 1) -> ListedWindow {
        ListedWindow(number: number, pid: pid ?? self.pid, layer: layer, bounds: bounds, alpha: alpha)
    }

    private func overlays(_ above: [ListedWindow], skipping: Set<Int> = [], ordinary: [Int: Int] = [:]) -> [Int] {
        NSWindow.ownWindows(above: above, pid: pid, region: region, layer: 0, skipping: skipping, ordinary: ordinary)
    }

    @Test func menusPanelsAndPopoversOverTheWindowAreIncludedTopmostFirst() {
        let menu = listed(31, layer: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        let card = listed(32, layer: Int(CGWindowLevelForKey(.floatingWindow)))
        let popover = listed(33)
        #expect(overlays([menu, card, popover]) == [31, 32, 33])
    }

    @Test func otherAppsWindowsAreLeftOut() {
        #expect(overlays([listed(41, pid: 99, layer: 101), listed(42)]) == [42])
    }

    @Test func windowsOutsideTheRegionOrInvisibleAreLeftOut() {
        let beside = listed(51, bounds: CGRect(x: 950, y: 100, width: 200, height: 200))
        let touching = listed(52, bounds: CGRect(x: 900, y: 100, width: 50, height: 50))
        let clear = listed(53, alpha: 0)
        let empty = listed(54, bounds: CGRect(x: 300, y: 300, width: 0, height: 0))
        let overlapping = listed(55, bounds: CGRect(x: 850, y: 650, width: 200, height: 200))
        #expect(overlays([beside, touching, clear, empty, overlapping]) == [55])
    }

    @Test func childWindowsTheSnapshotAlreadyHasAreLeftOut() {
        #expect(overlays([listed(61), listed(62), listed(63)], skipping: [61, 63]) == [62])
    }

    @Test func theAppsOtherOrdinaryWindowsInFrontAreLeftOut() {
        // Another main window or Settings in front at the same level: the snapshot is of this
        // window, so it stays whole. The same window raised to a higher level is drawn over it.
        let settings = listed(71)
        let pinned = listed(72, layer: 3)
        #expect(overlays([settings, pinned], ordinary: [71: 0, 72: 3]) == [72])
    }

    @Test func whatBelongsToAnotherWindowInFrontIsLeftOut() {
        // Another main window in front at the same level, with its Chromium page window, its
        // hover card and its sheet: none of it is this window's. A card of a window raised
        // above this one's level is drawn over it, as on screen.
        let page = listed(81)
        let card = listed(82, layer: Int(CGWindowLevelForKey(.floatingWindow)))
        let sheet = listed(83)
        let raisedCard = listed(84, layer: Int(CGWindowLevelForKey(.floatingWindow)))
        let menu = listed(85, layer: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        let other: [Int: Int] = [80: 0, 81: 0, 82: 0, 83: 0, 90: 3, 84: 3]
        #expect(overlays([menu, card, raisedCard, sheet, page], ordinary: other) == [85, 84])
    }

    @Test func theRegionIsInGlobalDisplayCoordinates() {
        // The primary screen is 1000 points tall; a window 100 points above its bottom edge.
        let frame = NSRect(x: 50, y: 100, width: 400, height: 300)
        #expect(NSWindow.globalRect(of: frame, primaryHeight: 1000) == CGRect(x: 50, y: 600, width: 400, height: 300))
        // A screen above the primary one has negative global y.
        let above = NSRect(x: 0, y: 1200, width: 400, height: 300)
        #expect(NSWindow.globalRect(of: above, primaryHeight: 1000) == CGRect(x: 0, y: -500, width: 400, height: 300))
    }

    @Test func readsTheWindowServersDescription() throws {
        let bounds = CGRect(x: 10, y: 20, width: 30, height: 40)
        let info: [String: Any] = [
            kCGWindowNumber as String: NSNumber(value: 7), kCGWindowOwnerPID as String: NSNumber(value: 4242),
            kCGWindowLayer as String: NSNumber(value: 101), kCGWindowAlpha as String: NSNumber(value: 0.5),
            kCGWindowBounds as String: bounds.dictionaryRepresentation,
        ]
        #expect(ListedWindow(info) == ListedWindow(number: 7, pid: 4242, layer: 101, bounds: bounds, alpha: 0.5))
        var missing = info
        missing[kCGWindowBounds as String] = nil
        #expect(ListedWindow(missing) == nil)
        // The window server leaves the alpha out of some entries: an opaque window.
        var opaque = info
        opaque[kCGWindowAlpha as String] = nil
        #expect(try #require(ListedWindow(opaque)).alpha == 1)
    }
}

import CmuxNextBrowserTabs
import CmuxNextDaemon
import Testing

/// Task p01-process-229: a hosted page's HTML fullscreen zooms its pane to fill the window, and its exit
/// (Escape, the page's own exit, the host's end, the tab's close) gives the zoom back. A pane the person had
/// zoomed stays zoomed.
@MainActor @Suite struct BrowserFullscreenPaneZoomTests {
    final class Page {}

    @MainActor final class Sends {
        var calls: [String] = []
        var send: BrowserFullscreenPaneZoom.Send { { [self] pane, on in calls.append("\(pane) \(on ? "on" : "off")") } }
    }

    @Test func enteringZoomsThePaneAndLeavingGivesItBack() {
        let zoom = BrowserFullscreenPaneZoom()
        let sends = Sends()
        let page = Page()
        let pane = PaneID(rawValue: 1)
        zoom.began(ObjectIdentifier(page), pane: pane, paneIsZoomed: false, send: sends.send)
        zoom.began(ObjectIdentifier(page), pane: pane, paneIsZoomed: true, send: sends.send)
        #expect(sends.calls == ["\(pane) on"], "one zoom per fullscreen")
        #expect(zoom.zoomedPane(of: ObjectIdentifier(page)) == pane)
        zoom.ended(ObjectIdentifier(page))
        zoom.ended(ObjectIdentifier(page))
        #expect(sends.calls == ["\(pane) on", "\(pane) off"], "one unzoom, and only of the pane it zoomed")
        #expect(zoom.zoomedPane(of: ObjectIdentifier(page)) == nil)
    }

    @Test func aPaneThePersonZoomedStaysZoomed() {
        let zoom = BrowserFullscreenPaneZoom()
        let sends = Sends()
        let page = Page()
        zoom.began(ObjectIdentifier(page), pane: PaneID(rawValue: 1), paneIsZoomed: true, send: sends.send)
        zoom.ended(ObjectIdentifier(page))
        #expect(sends.calls.isEmpty)
    }

    @Test func eachPageGivesBackItsOwnPane() {
        let zoom = BrowserFullscreenPaneZoom()
        let sends = Sends()
        let (first, second) = (Page(), Page())
        zoom.began(ObjectIdentifier(first), pane: PaneID(rawValue: 1), paneIsZoomed: false, send: sends.send)
        zoom.began(ObjectIdentifier(second), pane: PaneID(rawValue: 2), paneIsZoomed: false, send: sends.send)
        zoom.ended(ObjectIdentifier(first))
        #expect(sends.calls.last == "\(PaneID(rawValue: 1)) off")
        #expect(zoom.zoomedPane(of: ObjectIdentifier(second)) == PaneID(rawValue: 2))
        withExtendedLifetime((first, second)) {}
    }
}

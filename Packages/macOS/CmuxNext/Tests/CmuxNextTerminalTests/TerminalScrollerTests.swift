import AppKit
import CmuxNextDesign
@testable import CmuxNextTerminal
import Testing

/// SCROLLBARS-FOLLOW-MACOS: the terminal's scroller follows the macOS "Show scroll bars" setting.
/// Overlay: hidden at rest, shown only when the viewport moves through the scrollback, never in the
/// terminal's way. Legacy ("Always"): its own strip that the surface leaves free.
@MainActor @Suite(.serialized) struct TerminalScrollerTests {
    private func bar(total: UInt64, offset: UInt64, visible: UInt64) -> TerminalScrollbar {
        TerminalScrollbar(totalRows: total, offsetRows: offset, visibleRows: visible)
    }

    @Test func theDocumentStandsForTheScrollbackAndTheOriginForTheOffset() {
        let geometry = TerminalScrollerGeometry(bar: bar(total: 400, offset: 100, visible: 40), viewportHeight: 400)
        #expect(geometry.documentHeight == 4000)
        #expect(geometry.originY == 1000)
        #expect(geometry.row(forOriginY: 1000) == 100)
        // A drag past either end stays inside the scrollback.
        #expect(geometry.row(forOriginY: -50) == 0)
        #expect(geometry.row(forOriginY: 99_999) == 360)
    }

    @Test func nothingToScrollKeepsTheDocumentAtTheViewport() {
        for shown in [nil, bar(total: 40, offset: 0, visible: 40)] {
            let geometry = TerminalScrollerGeometry(bar: shown, viewportHeight: 400)
            #expect(geometry.documentHeight == 400)
            #expect(geometry.originY == 0)
        }
    }

    /// Output that follows the bottom is not scrolling; moving into the scrollback is.
    @Test func onlyAMoveThroughTheScrollbackShowsTheOverlayScroller() {
        let bottom = bar(total: 400, offset: 360, visible: 40)
        #expect(!TerminalScrollerGeometry.isUserMove(from: bottom, to: bar(total: 401, offset: 361, visible: 40)))
        #expect(TerminalScrollerGeometry.isUserMove(from: bottom, to: bar(total: 400, offset: 300, visible: 40)))
        #expect(TerminalScrollerGeometry.isUserMove(from: bar(total: 400, offset: 300, visible: 40), to: bottom))
        #expect(!TerminalScrollerGeometry.isUserMove(from: bottom, to: bottom))
        // The alternate screen (vim) has no scrollback.
        #expect(!TerminalScrollerGeometry.isUserMove(from: bottom, to: bar(total: 40, offset: 0, visible: 40)))
    }

    @Test func theScrollerFollowsTheSettingAndOnlyLegacyTakesRoomOrClicks() {
        let saved = SystemScrollers.preferredStyleOverride
        defer {
            SystemScrollers.preferredStyleOverride = saved
            SystemScrollers.systemStyleDidChange()
        }
        SystemScrollers.preferredStyleOverride = .overlay
        let scroller = TerminalScroller()
        var relayouts = 0
        scroller.onStyleChange = { relayouts += 1 }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        host.addSubview(scroller)
        scroller.frame = scroller.strip(in: host.bounds)
        #expect(scroller.scrollerStyle == .overlay)
        #expect(scroller.reservedWidth == 0)
        #expect(scroller.hitTest(NSPoint(x: 595, y: 200)) == nil)

        SystemScrollers.preferredStyleOverride = .legacy
        SystemScrollers.systemStyleDidChange()
        #expect(scroller.scrollerStyle == .legacy)
        #expect(!scroller.autohidesScrollers)
        #expect(scroller.reservedWidth == NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy))
        #expect(relayouts == 1)
    }
}

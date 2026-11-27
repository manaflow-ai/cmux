import AppKit
import CmuxNextDesign
@testable import CmuxNextHome
import Testing

/// Home's chat column against the window's top row (the person, 2026-11-24: the Chats button ran from
/// the pointer as the corner hover opened and closed the toolbar band, and in full screen the band
/// opened over it).
@MainActor
@Suite struct HomeTopRowTests {
    /// A window with no traffic lights (as in full screen) whose toolbar band is `frame` now and
    /// `reserve` fully open.
    private final class BandWindow: NSWindow, TitlebarAccessoryHosting {
        var frameNow: CGRect?
        var reserve: CGRect?
        var titlebarAccessoryFrame: CGRect? { frameNow }
        var titlebarAccessoryReserve: CGRect? { reserve }
    }

    private func column(in window: BandWindow) -> HomeChatColumnView {
        let column = HomeChatColumnView(content: NSView(frame: window.contentView!.bounds), compose: HomeChatComposeButton(label: "Compose"))
        column.frame = window.contentView!.bounds
        window.contentView!.addSubview(column)
        column.layoutSubtreeIfNeeded()
        return column
    }

    private func window() -> BandWindow {
        let window = BandWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: .borderless,
                                backing: .buffered, defer: true)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        return window
    }

    @Test func theButtonsSitAfterTheOpenBandOnItsLine() {
        let window = window()
        window.frameNow = NSRect(x: 12, y: 372, width: 0, height: 28)  // closed: 0 wide
        window.reserve = NSRect(x: 12, y: 372, width: 90, height: 28)
        let chats = column(in: window).chats
        #expect(chats.frame.minX >= 102 + HomeChatColumnView.buttonGap, "after the band's open width, not over it")
        #expect(abs(chats.frame.midY - 386) < 1, "on the band's line")
    }

    @Test func theBandOpeningNeverMovesTheButtons() {
        let window = window()
        window.reserve = NSRect(x: 12, y: 372, width: 90, height: 28)
        window.frameNow = NSRect(x: 12, y: 372, width: 0, height: 28)
        let column = column(in: window)
        let closed = column.chats.frame
        window.frameNow = window.reserve  // the corner hover opened it
        column.updateWindowControlsAvoidance()
        #expect(column.chats.frame == closed)
    }

    @Test func noBandAndNoLightsKeepsTheInset() {
        let window = window()
        let chats = column(in: window).chats
        #expect(chats.frame.minX == HomeChatColumnView.composeInset)
    }
}

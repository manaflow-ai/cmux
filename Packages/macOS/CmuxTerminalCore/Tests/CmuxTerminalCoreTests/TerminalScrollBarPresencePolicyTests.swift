import Testing
import CmuxTerminalCore

/// The scroller's presence may follow scrollback only where presence reserves
/// no layout; a legacy gutter that came and went with history would make the
/// terminal grid a function of the terminal's own content (#12885, #3051).
@Suite struct TerminalScrollBarPresencePolicyTests {
    private typealias Policy = TerminalScrollBarPresencePolicy

    @Test("A legacy scroller is present regardless of scrollback")
    func legacyReservesTheGutter() {
        #expect(Policy(allowedBySettings: true, scrollerStyle: .legacy, hasScrollback: false).isPresent)
        #expect(Policy(allowedBySettings: true, scrollerStyle: .legacy, hasScrollback: nil).isPresent)
        #expect(Policy(allowedBySettings: true, scrollerStyle: .legacy, hasScrollback: true).isPresent)
    }

    @Test("An overlay scroller follows scrollback and assumes history until told otherwise")
    func overlayFollowsScrollback() {
        #expect(!Policy(allowedBySettings: true, scrollerStyle: .overlay, hasScrollback: false).isPresent)
        #expect(Policy(allowedBySettings: true, scrollerStyle: .overlay, hasScrollback: true).isPresent)
        #expect(Policy(allowedBySettings: true, scrollerStyle: .overlay, hasScrollback: nil).isPresent)
    }

    @Test("A manual mirror shows local scrolling when its source grid overflows the pane")
    func manualMirrorOverflowShowsOverlayScroller() {
        #expect(Policy(allowedBySettings: true, scrollerStyle: .overlay, hasScrollback: false,
            hasManualMirrorOverflow: true).isPresent)
        #expect(!Policy(allowedBySettings: true, scrollerStyle: .overlay, hasScrollback: false,
            hasManualMirrorOverflow: false).isPresent)
    }

    @Test("Settings that disallow the scroller win over every style")
    func settingsWin() {
        #expect(!Policy(allowedBySettings: false, scrollerStyle: .legacy, hasScrollback: true).isPresent)
        #expect(!Policy(allowedBySettings: false, scrollerStyle: .overlay, hasScrollback: true).isPresent)
    }
}

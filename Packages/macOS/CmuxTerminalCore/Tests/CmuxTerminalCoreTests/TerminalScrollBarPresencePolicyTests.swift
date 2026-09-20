import Testing
import CmuxTerminalCore

/// The scroller's presence may follow scrollback only where presence reserves
/// no layout; a legacy gutter that came and went with history would make the
/// terminal grid a function of the terminal's own content (#12885, #3051).
@Suite struct TerminalScrollBarPresencePolicyTests {
    private typealias Policy = TerminalScrollBarPresencePolicy

    @Test("A legacy scroller is present regardless of scrollback")
    func legacyReservesTheGutter() {
        #expect(Policy.isPresent(allowedBySettings: true, scrollerStyle: .legacy, hasScrollback: false))
        #expect(Policy.isPresent(allowedBySettings: true, scrollerStyle: .legacy, hasScrollback: nil))
        #expect(Policy.isPresent(allowedBySettings: true, scrollerStyle: .legacy, hasScrollback: true))
    }

    @Test("An overlay scroller follows scrollback and assumes history until told otherwise")
    func overlayFollowsScrollback() {
        #expect(!Policy.isPresent(allowedBySettings: true, scrollerStyle: .overlay, hasScrollback: false))
        #expect(Policy.isPresent(allowedBySettings: true, scrollerStyle: .overlay, hasScrollback: true))
        #expect(Policy.isPresent(allowedBySettings: true, scrollerStyle: .overlay, hasScrollback: nil))
    }

    @Test("Settings that disallow the scroller win over every style")
    func settingsWin() {
        #expect(!Policy.isPresent(allowedBySettings: false, scrollerStyle: .legacy, hasScrollback: true))
        #expect(!Policy.isPresent(allowedBySettings: false, scrollerStyle: .overlay, hasScrollback: true))
    }

    @Test("legacy visual presentation follows the macOS preference")
    func legacyVisualPresentationFollowsPreference() {
        let policy = TerminalScrollBarDisplayPolicy()

        #expect(policy.shouldDisplay(
            allowedBySettings: true,
            scrollerStyle: .legacy,
            hasScrollback: false,
            preference: .always,
            isPointerOverScrollbar: false,
            isLiveScrolling: false
        ))
        #expect(!policy.shouldDisplay(
            allowedBySettings: true,
            scrollerStyle: .legacy,
            hasScrollback: false,
            preference: .automatic,
            isPointerOverScrollbar: false,
            isLiveScrolling: false
        ))
        #expect(policy.shouldDisplay(
            allowedBySettings: true,
            scrollerStyle: .legacy,
            hasScrollback: false,
            preference: .automatic,
            isPointerOverScrollbar: true,
            isLiveScrolling: false
        ))
        #expect(!policy.shouldDisplay(
            allowedBySettings: true,
            scrollerStyle: .legacy,
            hasScrollback: false,
            preference: .whenScrolling,
            isPointerOverScrollbar: true,
            isLiveScrolling: false
        ))
        #expect(policy.shouldDisplay(
            allowedBySettings: true,
            scrollerStyle: .legacy,
            hasScrollback: false,
            preference: .whenScrolling,
            isPointerOverScrollbar: false,
            isLiveScrolling: true
        ))
        #expect(policy.shouldDisplay(
            allowedBySettings: true,
            scrollerStyle: .overlay,
            hasScrollback: true,
            preference: .whenScrolling,
            isPointerOverScrollbar: false,
            isLiveScrolling: false
        ))
    }
}

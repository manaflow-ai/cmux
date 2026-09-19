import Testing
@testable import CmuxTerminalCore

@Suite("Terminal scroll bar presence policy")
struct TerminalScrollBarPresencePolicyTests {
    @Test("legacy scrollers stay present regardless of scrollback")
    func legacyStyleReservesStableGutter() {
        let policy = TerminalScrollBarPresencePolicy()

        #expect(policy.isPresent(allowedBySettings: true, scrollerStyle: .legacy, hasScrollback: false))
        #expect(policy.isPresent(allowedBySettings: true, scrollerStyle: .legacy, hasScrollback: nil))
        #expect(policy.isPresent(allowedBySettings: true, scrollerStyle: .legacy, hasScrollback: true))
    }

    @Test("overlay scrollers follow scrollback")
    func overlayStyleDoesNotReserveGutter() {
        let policy = TerminalScrollBarPresencePolicy()

        #expect(!policy.isPresent(allowedBySettings: true, scrollerStyle: .overlay, hasScrollback: false))
        #expect(policy.isPresent(allowedBySettings: true, scrollerStyle: .overlay, hasScrollback: nil))
        #expect(policy.isPresent(allowedBySettings: true, scrollerStyle: .overlay, hasScrollback: true))
    }

    @Test("disabled settings always hide the scrollbar")
    func settingsOverrideStyle() {
        let policy = TerminalScrollBarPresencePolicy()

        #expect(!policy.isPresent(allowedBySettings: false, scrollerStyle: .legacy, hasScrollback: true))
        #expect(!policy.isPresent(allowedBySettings: false, scrollerStyle: .overlay, hasScrollback: true))
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

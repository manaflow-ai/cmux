import Testing
@testable import CmuxMobileWorkspaces

/// Design/terminal P5: "Reattaching…" appears in the title pill only when a
/// reattach lasts 400 ms; a 250 ms reattach shows nothing.
@Suite struct ReattachDebounceTests {
    let t0 = ContinuousClock.now

    @Test func quickReattachShowsNothing() {
        var debounce = ReattachDebounce<ContinuousClock.Instant>()
        let check = debounce.update(reattaching: true, at: t0)
        #expect(check == t0.advanced(by: .milliseconds(400)))
        #expect(!debounce.isShown(at: t0))
        #expect(!debounce.isShown(at: t0.advanced(by: .milliseconds(250))))
        // Attached again at 250 ms: nothing to check, never shown.
        #expect(debounce.update(reattaching: false, at: t0.advanced(by: .milliseconds(250))) == nil)
        #expect(!debounce.isShown(at: t0.advanced(by: .milliseconds(500))))
    }

    @Test func slowReattachShowsAfter400ms() {
        var debounce = ReattachDebounce<ContinuousClock.Instant>()
        _ = debounce.update(reattaching: true, at: t0)
        #expect(!debounce.isShown(at: t0.advanced(by: .milliseconds(399))))
        #expect(debounce.isShown(at: t0.advanced(by: .milliseconds(400))))
        #expect(debounce.isShown(at: t0.advanced(by: .seconds(3))))
        // Done: hidden at once.
        _ = debounce.update(reattaching: false, at: t0.advanced(by: .seconds(3)))
        #expect(!debounce.isShown(at: t0.advanced(by: .seconds(3))))
    }

    @Test func repeatedReattachingKeepsTheStart() {
        var debounce = ReattachDebounce<ContinuousClock.Instant>()
        _ = debounce.update(reattaching: true, at: t0)
        // A second reattaching state (another Mac name) does not restart the wait.
        let check = debounce.update(reattaching: true, at: t0.advanced(by: .milliseconds(300)))
        #expect(check == t0.advanced(by: .milliseconds(400)))
        // Already past the delay: shown, no further check.
        #expect(debounce.update(reattaching: true, at: t0.advanced(by: .milliseconds(450))) == nil)
        #expect(debounce.isShown(at: t0.advanced(by: .milliseconds(450))))
    }

    @Test func aNewReattachWaitsAgain() {
        var debounce = ReattachDebounce<ContinuousClock.Instant>()
        _ = debounce.update(reattaching: true, at: t0)
        _ = debounce.update(reattaching: false, at: t0.advanced(by: .seconds(1)))
        let start = t0.advanced(by: .seconds(2))
        #expect(debounce.update(reattaching: true, at: start) == start.advanced(by: .milliseconds(400)))
        #expect(!debounce.isShown(at: start.advanced(by: .milliseconds(100))))
    }
}

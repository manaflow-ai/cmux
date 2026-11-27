@testable import CmuxNextPages
import Foundation
import Testing

/// Recovery from a code layer that breaks the UI (Leo, 2026-11-14: "I want people to not
/// accidentally soft lock themselves and like have good recovery options or whatever"): a page that
/// does not start from an overlay install falls every page back to the bundle, once per install,
/// and a launch that ignores every layer serves none whatever cmux Live says.
struct WebDevOverrideRecoveryTests {
    private let overlay = URL(fileURLWithPath: "/Users/someone/layers/pr-1", isDirectory: true)

    private func held(stamp: String = "1") -> WebDevOverride.Held {
        var held = WebDevOverride.Held()
        held.read = WebDevOverride(overlay: overlay, stamp: Data(stamp.utf8))
        return held
    }

    private func install(_ stamp: String = "1") -> WebDevOverride.OverlayInstall {
        WebDevOverride.OverlayInstall(overlay: overlay, stamp: Data(stamp.utf8))
    }

    @Test func anInstallThatDidNotStartIsRefusedInMemoryOnce() {
        var state = held()
        #expect(state.inForce.servedInstall == install())
        do { let result = state.fallBack(from: install(), reason: "Settings did not start: its web content process ended"); #expect(result) }
        #expect(state.inForce.refusal == "Settings did not start: its web content process ended")
        #expect(state.inForce.servedInstall == nil)
        #expect(state.inForce.overlayRoot("pages/settings") == nil)
        // A second failure of the same install changes nothing: no reload loop.
        do { let result = state.fallBack(from: install(), reason: "again"); #expect(!result) }
        #expect(state.inForce.refusal == "Settings did not start: its web content process ended")
    }

    @Test func aNewerInstallIsServedAgainAndAnOldDocumentCannotRefuseIt() {
        var state = held()
        do { let result = state.fallBack(from: install("1"), reason: "broke"); #expect(result) }
        state.read = WebDevOverride(overlay: overlay, stamp: Data("2".utf8))
        #expect(state.inForce.refusal == nil)
        #expect(state.inForce.servedInstall == install("2"))
        // A late failure of a document from the old install does not refuse the new one.
        do { let result = state.fallBack(from: install("1"), reason: "late"); #expect(!result) }
        #expect(state.inForce.servedInstall == install("2"))
    }

    @Test func nothingFallsBackWhenNoOverlayIsServed() {
        var none = WebDevOverride.Held()
        do { let result = none.fallBack(from: install(), reason: "x"); #expect(!result) }
        var off = held()
        off.allowed = false
        do { let result = off.fallBack(from: install(), reason: "x"); #expect(!result) }
        var abi = held()
        abi.read.refusal = "needs web ABI 9"
        do { let result = abi.fallBack(from: install(), reason: "x"); #expect(!result) }
    }

    @Test func aRunThatIgnoresLayersServesNoneWhateverCmuxLiveSays() {
        var state = held()
        state.ignoredThisRun = true
        state.allowed = true
        #expect(state.inForce == WebDevOverride())
        #expect(!state.inForce.isActive)
        do { let result = state.fallBack(from: install(), reason: "x"); #expect(!result) }
    }

    @Test func aDocumentFromAnOverlayThatFailsBeforeItSpeaksDidNotStart() {
        var check = OverlayStartCheck()
        check.committed(install())
        do { let result = check.failed(); #expect(result == install()) }
        // Judged once: the reload that follows is another document.
        do { let result = check.failed(); #expect(result == nil) }
    }

    @Test func aDocumentThatSpokeStarted() {
        var check = OverlayStartCheck()
        check.committed(install())
        do { let result = check.spoke(); #expect(result) }
        do { let result = check.failed(); #expect(result == nil) }
        do { let result = check.deadline(shown: true); #expect(result == nil) }
        do { let result = check.spoke(); #expect(!result) }
    }

    @Test func silenceCountsOnlyWhileShown() {
        var check = OverlayStartCheck()
        check.committed(install())
        do { let result = check.deadline(shown: false); #expect(result == nil) }
        // Still watched: a hidden document that then ends did not start either.
        #expect(check.watching == install())
        do { let result = check.deadline(shown: true); #expect(result == install()) }
    }

    /// Slow is not broken: a document's silence counts from its load, so a page a loaded Mac took
    /// longer than ``OverlayStartCheck/readyWithin`` to load is not taken for a broken install
    /// (cmux#50470's layer: "Onboarding did not start: its page code did not answer in 20 s").
    @Test func silenceCountsFromTheDocumentsLoadNotItsCommit() {
        var check = OverlayStartCheck()
        check.committed(install())
        #expect(!check.loaded)
        #expect(OverlayStartCheck.loadWithin > OverlayStartCheck.readyWithin * 4)
        do { let result = check.documentLoaded(); #expect(result) }
        #expect(check.loaded)
        // The next document starts unloaded again.
        check.committed(install())
        #expect(!check.loaded)
    }

    @Test func aDocumentThatSpokeBeforeItLoadedArmsNoDeadline() {
        var check = OverlayStartCheck()
        check.committed(install())
        _ = check.spoke()
        do { let result = check.documentLoaded(); #expect(!result) }
        var bundled = OverlayStartCheck()
        bundled.committed(nil)
        do { let result = bundled.documentLoaded(); #expect(!result) }
    }

    @Test func aBundledDocumentIsNeverJudged() {
        var check = OverlayStartCheck()
        check.committed(nil)
        do { let result = check.failed(); #expect(result == nil) }
        do { let result = check.deadline(shown: true); #expect(result == nil) }
    }
}

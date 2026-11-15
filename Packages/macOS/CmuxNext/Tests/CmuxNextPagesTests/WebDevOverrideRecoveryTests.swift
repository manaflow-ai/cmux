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
        #expect(state.fallBack(from: install(), reason: "Settings did not start: its web content process ended"))
        #expect(state.inForce.refusal == "Settings did not start: its web content process ended")
        #expect(state.inForce.servedInstall == nil)
        #expect(state.inForce.overlayRoot("pages/settings") == nil)
        // A second failure of the same install changes nothing: no reload loop.
        #expect(!state.fallBack(from: install(), reason: "again"))
        #expect(state.inForce.refusal == "Settings did not start: its web content process ended")
    }

    @Test func aNewerInstallIsServedAgainAndAnOldDocumentCannotRefuseIt() {
        var state = held()
        #expect(state.fallBack(from: install("1"), reason: "broke"))
        state.read = WebDevOverride(overlay: overlay, stamp: Data("2".utf8))
        #expect(state.inForce.refusal == nil)
        #expect(state.inForce.servedInstall == install("2"))
        // A late failure of a document from the old install does not refuse the new one.
        #expect(!state.fallBack(from: install("1"), reason: "late"))
        #expect(state.inForce.servedInstall == install("2"))
    }

    @Test func nothingFallsBackWhenNoOverlayIsServed() {
        var none = WebDevOverride.Held()
        #expect(!none.fallBack(from: install(), reason: "x"))
        var off = held()
        off.allowed = false
        #expect(!off.fallBack(from: install(), reason: "x"))
        var abi = held()
        abi.read.refusal = "needs web ABI 9"
        #expect(!abi.fallBack(from: install(), reason: "x"))
    }

    @Test func aRunThatIgnoresLayersServesNoneWhateverCmuxLiveSays() {
        var state = held()
        state.ignoredThisRun = true
        state.allowed = true
        #expect(state.inForce == WebDevOverride())
        #expect(!state.inForce.isActive)
        #expect(!state.fallBack(from: install(), reason: "x"))
    }

    @Test func aDocumentFromAnOverlayThatFailsBeforeItSpeaksDidNotStart() {
        var check = OverlayStartCheck()
        check.committed(install())
        #expect(check.failed() == install())
        // Judged once: the reload that follows is another document.
        #expect(check.failed() == nil)
    }

    @Test func aDocumentThatSpokeStarted() {
        var check = OverlayStartCheck()
        check.committed(install())
        #expect(check.spoke())
        #expect(check.failed() == nil)
        #expect(check.deadline(shown: true) == nil)
        #expect(!check.spoke())
    }

    @Test func silenceCountsOnlyWhileShown() {
        var check = OverlayStartCheck()
        check.committed(install())
        #expect(check.deadline(shown: false) == nil)
        // Still watched: a hidden document that then ends did not start either.
        #expect(check.watching == install())
        #expect(check.deadline(shown: true) == install())
    }

    @Test func aBundledDocumentIsNeverJudged() {
        var check = OverlayStartCheck()
        check.committed(nil)
        #expect(check.failed() == nil)
        #expect(check.deadline(shown: true) == nil)
    }
}

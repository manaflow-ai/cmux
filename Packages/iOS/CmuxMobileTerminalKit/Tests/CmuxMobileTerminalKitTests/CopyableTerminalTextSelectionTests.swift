import Foundation
import Testing
@testable import CmuxMobileTerminalKit

@Suite("CopyableTerminalTextSelection: View as Text pick + fallback")
struct CopyableTerminalTextSelectionTests {
    typealias Candidate = CopyableTerminalTextCandidate
    let selection = CopyableTerminalTextSelection()

    private func visible(_ id: String?) -> Candidate {
        Candidate(hostSurfaceID: id, hasSurface: true, hasWindow: true, isHidden: false, alpha: 1)
    }

    private func hidden(_ id: String?) -> Candidate {
        Candidate(hostSurfaceID: id, hasSurface: true, hasWindow: true, isHidden: true, alpha: 1)
    }

    @Test("id-scoped, on-screen surface is eligible")
    func eligibleMatch() {
        #expect(selection.isEligible(visible("surface:1"), for: "surface:1"))
    }

    @Test("a different id is never eligible")
    func excludedByID() {
        #expect(!selection.isEligible(visible("surface:2"), for: "surface:1"))
        #expect(!selection.isEligible(visible(nil), for: "surface:1"))
    }

    @Test("a dismantling view with no surface is excluded")
    func excludedWhenNoSurface() {
        let dismantling = Candidate(
            hostSurfaceID: "surface:1", hasSurface: false, hasWindow: true, isHidden: false, alpha: 1
        )
        #expect(!selection.isEligible(dismantling, for: "surface:1"))
    }

    @Test("a dismantled view with a retained surface is excluded")
    func dismantledSurfaceIsExcludedEvenWhenRetained() {
        let dismantled = Candidate(
            hostSurfaceID: "surface:1",
            hasSurface: true,
            isDismantled: true,
            hasWindow: false,
            isHidden: true,
            alpha: 0
        )
        #expect(!selection.isEligible(dismantled, for: "surface:1"))
        #expect(selection.chosenIndex(from: [dismantled], for: "surface:1") == nil)
    }

    @Test("transitioning window/hidden/alpha state does not exclude the live requested surface")
    func transitioningSurfaceStillEligible() {
        let detached = Candidate(
            hostSurfaceID: "surface:1", hasSurface: true, hasWindow: false, isHidden: false, alpha: 1
        )
        let hidden = Candidate(
            hostSurfaceID: "surface:1", hasSurface: true, hasWindow: true, isHidden: true, alpha: 1
        )
        let transparent = Candidate(
            hostSurfaceID: "surface:1", hasSurface: true, hasWindow: true, isHidden: false, alpha: 0
        )
        #expect(selection.isEligible(detached, for: "surface:1"))
        #expect(selection.isEligible(hidden, for: "surface:1"))
        #expect(selection.isEligible(transparent, for: "surface:1"))
    }

    @Test("chosenIndex returns the first visible eligible match")
    func chosenIndexDeterministic() {
        let candidates = [
            visible("surface:2"),       // wrong id
            hidden("surface:1"),        // eligible fallback, but not preferred
            visible("surface:1"),       // first eligible
            visible("surface:1"),       // also eligible, but later
        ]
        #expect(selection.chosenIndex(from: candidates, for: "surface:1") == 2)
    }

    @Test("chosenIndex falls back to transitioning eligible surface when none are visible")
    func chosenIndexTransitionFallback() {
        let candidates = [
            visible("surface:2"),
            hidden("surface:1"),
        ]
        #expect(selection.chosenIndex(from: candidates, for: "surface:1") == 1)
    }

    @Test("chosenIndex is nil when nothing is eligible")
    func chosenIndexNone() {
        let candidates = [visible("surface:2"), visible(nil)]
        #expect(selection.chosenIndex(from: candidates, for: "surface:1") == nil)
    }

    @Test("non-empty SCREEN wins")
    func screenWins() {
        #expect(
            selection.resolvedText(screen: "scrollback", viewport: "visible")
                == "scrollback"
        )
    }

    @Test("empty-string SCREEN falls back to VIEWPORT")
    func emptyScreenFallsBackToViewport() {
        // The exact reported bug: SCREEN read OK but zero-byte (non-nil ""), so a
        // plain `screen ?? viewport` would keep the empty string and the sheet
        // showed its empty state even though the viewport had content.
        #expect(
            selection.resolvedText(screen: "", viewport: "visible text")
                == "visible text"
        )
    }

    @Test("nil SCREEN falls back to VIEWPORT")
    func nilScreenFallsBackToViewport() {
        #expect(
            selection.resolvedText(screen: nil, viewport: "visible text")
                == "visible text"
        )
    }

    @Test("both empty/nil yields nil (honest empty state)")
    func bothEmptyYieldsNil() {
        #expect(selection.resolvedText(screen: "", viewport: "") == nil)
        #expect(selection.resolvedText(screen: nil, viewport: nil) == nil)
        #expect(selection.resolvedText(screen: "", viewport: nil) == nil)
    }
}

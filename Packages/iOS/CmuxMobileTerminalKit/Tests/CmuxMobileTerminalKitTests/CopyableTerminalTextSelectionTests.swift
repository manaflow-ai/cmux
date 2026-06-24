import Foundation
import Testing
@testable import CmuxMobileTerminalKit

@Suite("CopyableTerminalTextSelection: View as Text pick + fallback")
struct CopyableTerminalTextSelectionTests {
    typealias Candidate = CopyableTerminalTextSelection.Candidate

    private func visible(_ id: String?) -> Candidate {
        Candidate(hostSurfaceID: id, hasSurface: true, hasWindow: true, isHidden: false, alpha: 1)
    }

    @Test("id-scoped, on-screen surface is eligible")
    func eligibleMatch() {
        #expect(CopyableTerminalTextSelection.isEligible(visible("surface:1"), for: "surface:1"))
    }

    @Test("a different id is never eligible")
    func excludedByID() {
        #expect(!CopyableTerminalTextSelection.isEligible(visible("surface:2"), for: "surface:1"))
        #expect(!CopyableTerminalTextSelection.isEligible(visible(nil), for: "surface:1"))
    }

    @Test("a dismantling view with no surface is excluded")
    func excludedWhenNoSurface() {
        let dismantling = Candidate(
            hostSurfaceID: "surface:1", hasSurface: false, hasWindow: true, isHidden: false, alpha: 1
        )
        #expect(!CopyableTerminalTextSelection.isEligible(dismantling, for: "surface:1"))
    }

    @Test("off-window / hidden / transparent surfaces are excluded")
    func excludedWhenOffScreen() {
        let detached = Candidate(
            hostSurfaceID: "surface:1", hasSurface: true, hasWindow: false, isHidden: false, alpha: 1
        )
        let hidden = Candidate(
            hostSurfaceID: "surface:1", hasSurface: true, hasWindow: true, isHidden: true, alpha: 1
        )
        let transparent = Candidate(
            hostSurfaceID: "surface:1", hasSurface: true, hasWindow: true, isHidden: false, alpha: 0
        )
        #expect(!CopyableTerminalTextSelection.isEligible(detached, for: "surface:1"))
        #expect(!CopyableTerminalTextSelection.isEligible(hidden, for: "surface:1"))
        #expect(!CopyableTerminalTextSelection.isEligible(transparent, for: "surface:1"))
    }

    @Test("chosenIndex returns the first (lowest-keyed) eligible match")
    func chosenIndexDeterministic() {
        let candidates = [
            visible("surface:2"),       // wrong id
            visible("surface:1"),       // first eligible
            visible("surface:1"),       // also eligible, but later
        ]
        #expect(CopyableTerminalTextSelection.chosenIndex(from: candidates, for: "surface:1") == 1)
    }

    @Test("chosenIndex is nil when nothing is eligible")
    func chosenIndexNone() {
        let candidates = [visible("surface:2"), visible(nil)]
        #expect(CopyableTerminalTextSelection.chosenIndex(from: candidates, for: "surface:1") == nil)
    }

    @Test("non-empty SCREEN wins")
    func screenWins() {
        #expect(
            CopyableTerminalTextSelection.resolvedText(screen: "scrollback", viewport: "visible")
                == "scrollback"
        )
    }

    @Test("empty-string SCREEN falls back to VIEWPORT")
    func emptyScreenFallsBackToViewport() {
        // The exact reported bug: SCREEN read OK but zero-byte (non-nil ""), so a
        // plain `screen ?? viewport` would keep the empty string and the sheet
        // showed its empty state even though the viewport had content.
        #expect(
            CopyableTerminalTextSelection.resolvedText(screen: "", viewport: "visible text")
                == "visible text"
        )
    }

    @Test("nil SCREEN falls back to VIEWPORT")
    func nilScreenFallsBackToViewport() {
        #expect(
            CopyableTerminalTextSelection.resolvedText(screen: nil, viewport: "visible text")
                == "visible text"
        )
    }

    @Test("both empty/nil yields nil (honest empty state)")
    func bothEmptyYieldsNil() {
        #expect(CopyableTerminalTextSelection.resolvedText(screen: "", viewport: "") == nil)
        #expect(CopyableTerminalTextSelection.resolvedText(screen: nil, viewport: nil) == nil)
        #expect(CopyableTerminalTextSelection.resolvedText(screen: "", viewport: nil) == nil)
    }
}

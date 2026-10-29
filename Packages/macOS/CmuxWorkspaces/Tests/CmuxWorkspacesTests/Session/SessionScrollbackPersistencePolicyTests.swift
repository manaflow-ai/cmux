import Foundation
import Testing
@testable import CmuxWorkspaces

@Suite("Session scrollback persistence policy")
struct SessionScrollbackPersistencePolicyTests {
    private let policy = SessionScrollbackPersistencePolicy()

    /// The line tail keeps the newest lines and drops a partial first line.
    @Test func tailLinesKeepsTheNewestLines() {
        #expect(policy.tailLines("a\nb\nc", maxLines: 2) == "b\nc")
        #expect(policy.tailLines("a\nb\n", maxLines: 2) == "b\n")
        #expect(policy.tailLines("a", maxLines: 2) == "a")
        #expect(policy.tailLines("a\nb", maxLines: 0) == "")
    }

    /// One line past the line cap keeps the newest lines and is marked truncated.
    @Test func lineCapKeepsTheNewestLinesAndMarksTruncation() {
        let lineCount = SessionScrollbackPersistencePolicy.sessionSnapshotMaxLines + 1
        let source = (0..<lineCount).map { "line-\($0)" }.joined(separator: "\n")

        let persisted = policy.persistedScrollback(source)
        let lines = persisted.text?.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        #expect(persisted.wasTruncated)
        #expect(lines?.count == SessionScrollbackPersistencePolicy.sessionSnapshotMaxLines)
        #expect(lines?.first == "line-1")
        #expect(lines?.last == "line-\(lineCount - 1)")
    }

    /// Past the character cap the tail matches character clipping and is marked truncated.
    @Test func characterCapKeepsTheAnsiSafeTail() {
        let maxChars = SessionScrollbackPersistencePolicy.sessionSnapshotMaxCharacters
        let source = "HEAD" + String(repeating: "x", count: maxChars)

        let persisted = policy.persistedScrollback(source)

        #expect(persisted.wasTruncated)
        #expect(persisted.text?.count == maxChars)
        #expect(persisted.text == policy.truncatedScrollback(source))
        #expect(persisted.text?.hasPrefix("HEAD") == false)
    }

    /// Text under or exactly at either cap is kept as is and not marked.
    @Test func textThatFitsBothCapsIsUnmarked() {
        let short = "alpha\nbeta\n"
        let atLineCap = (0..<SessionScrollbackPersistencePolicy.sessionSnapshotMaxLines)
            .map { "L\($0)" }
            .joined(separator: "\n")
        let atCharCap = String(
            repeating: "y",
            count: SessionScrollbackPersistencePolicy.sessionSnapshotMaxCharacters
        )

        let shortPersisted = policy.persistedScrollback(short)
        let linePersisted = policy.persistedScrollback(atLineCap)
        let charPersisted = policy.persistedScrollback(atCharCap)

        #expect(shortPersisted.wasTruncated == false)
        #expect(shortPersisted.text == short)
        #expect(linePersisted.wasTruncated == false)
        #expect(linePersisted.text == atLineCap)
        #expect(charPersisted.wasTruncated == false)
        #expect(charPersisted.text == atCharCap)
    }

    /// A fallback entry stores its text and truncation together, and a fresh
    /// complete capture replaces both, clearing the marker.
    @Test func fallbackEntryCarriesTextAndTruncationAndAFreshCaptureClearsTheMarker() {
        let fallback = policy.persistedSnapshotScrollback(
            capturedScrollback: nil,
            fallbackScrollback: "already-bounded tail\n",
            fallbackWasTruncated: true
        )
        #expect(fallback.text == "already-bounded tail\n")
        #expect(fallback.wasTruncated)

        var cache: [UUID: SessionPersistedScrollback] = [:]
        let panelId = UUID(uuidString: "00000000-0000-0000-0000-000000000157")!
        cache.rememberRestoredScrollback(
            fallback.text,
            for: panelId,
            wasTruncated: fallback.wasTruncated
        )
        let stored = cache[panelId]
        #expect(stored?.text == fallback.text)
        #expect(stored?.wasTruncated == fallback.wasTruncated)

        let fresh = policy.persistedSnapshotScrollback(
            capturedScrollback: "fresh\n",
            fallbackScrollback: stored?.text,
            fallbackWasTruncated: stored?.wasTruncated == true
        )
        #expect(fresh.text == "fresh\n")
        #expect(fresh.wasTruncated == false)
        cache.rememberRestoredScrollback(fresh.text, for: panelId, wasTruncated: fresh.wasTruncated)
        #expect(cache[panelId]?.text == "fresh\n")
        #expect(cache[panelId]?.wasTruncated == false)

        cache.rememberRestoredScrollback(nil, for: panelId, wasTruncated: true)
        #expect(cache[panelId] == nil)
    }

    /// An empty capture does not keep a fallback when fallback is disallowed.
    @Test func disallowedFallbackStoresNothing() {
        let persisted = policy.persistedSnapshotScrollback(
            capturedScrollback: nil,
            fallbackScrollback: "fallback-value",
            fallbackWasTruncated: true,
            allowFallbackScrollback: false
        )
        #expect(persisted.text == nil)
        #expect(persisted.wasTruncated == false)
    }

    /// A cut that lands inside a CSI sequence starts after that sequence.
    @Test func characterClipAvoidsAPartialCSISequence() {
        let maxChars = SessionScrollbackPersistencePolicy.sessionSnapshotMaxCharacters
        let source = "\u{001B}[31m"
            + String(repeating: "X", count: maxChars - 7)
            + "\u{001B}[0m"
        let truncated = policy.truncatedScrollback(source)
        #expect(truncated?.hasPrefix("31m") == false)
        #expect(truncated?.hasPrefix("[31m") == false)
        #expect(truncated?.hasPrefix("m") == false)
    }

    /// A cut that lands inside an OSC sequence starts on the visible tail.
    @Test func characterClipAvoidsAPartialOSCSequence() {
        let maxChars = SessionScrollbackPersistencePolicy.sessionSnapshotMaxCharacters
        let sequence = "\u{001B}]8;;https://example.com/path\u{0007}"
        let cutOffset = 10
        let tailCount = maxChars - (sequence.count - cutOffset)
        let source = sequence + String(repeating: "X", count: tailCount)
        let truncated = policy.truncatedScrollback(source)
        #expect(truncated?.hasPrefix("X") == true)
        #expect(truncated?.contains("example.com/path") == false)
    }

    /// A string-terminator OSC is not left as a partial escape.
    @Test func characterClipAvoidsAPartialOSCSequenceWithSTTerminator() {
        let maxChars = SessionScrollbackPersistencePolicy.sessionSnapshotMaxCharacters
        let sequence = "\u{001B}]2;window title\u{001B}\\"
        let cutOffset = 6
        let tailCount = maxChars - (sequence.count - cutOffset)
        let source = sequence + String(repeating: "Y", count: tailCount)
        let truncated = policy.truncatedScrollback(source)
        #expect(truncated?.hasPrefix("Y") == true)
        #expect(truncated?.contains("window title") == false)
    }

    /// SOS, and the other string sequences, are skipped the same way.
    @Test func characterClipAvoidsPartialStringSequences() {
        let maxChars = SessionScrollbackPersistencePolicy.sessionSnapshotMaxCharacters
        let sequence = "\u{001B}Xprivate status payload\u{001B}\\"
        let cutOffset = 8
        let tailCount = maxChars - (sequence.count - cutOffset)
        let source = sequence + String(repeating: "Z", count: tailCount)
        let truncated = policy.truncatedScrollback(source)
        #expect(truncated?.hasPrefix("Z") == true)
        #expect(truncated?.contains("private status payload") == false)

        for (marker, fill) in [("P", "D"), ("_", "A"), ("^", "M")] {
            let marked = "\u{001B}\(marker)control payload\u{001B}\\"
            let markedTail = maxChars - (marked.count - 6)
            let markedSource = marked + String(repeating: fill, count: markedTail)
            let clipped = policy.truncatedScrollback(markedSource)
            #expect(clipped?.hasPrefix(fill) == true)
            #expect(clipped?.contains("control payload") == false)
        }
    }

    /// BEL ends OSC, not DCS.
    @Test func belDoesNotTerminateAPartialDCSSequence() {
        let maxChars = SessionScrollbackPersistencePolicy.sessionSnapshotMaxCharacters
        let sequence = "\u{001B}Pbefore\u{0007}after\u{001B}\\"
        let cutOffset = 5
        let tailCount = maxChars - (sequence.count - cutOffset)
        let source = sequence + String(repeating: "Q", count: tailCount)
        let truncated = policy.truncatedScrollback(source)
        #expect(truncated?.hasPrefix("Q") == true)
        #expect(truncated?.contains("after") == false)
    }

    /// A long OSC uses the post-cut scan budget instead of keeping the payload.
    @Test func longOSCUsesThePostCutScanBudget() {
        let maxChars = SessionScrollbackPersistencePolicy.sessionSnapshotMaxCharacters
        let prefix = "\u{001B}]2;"
        let payload = String(repeating: "T", count: 1_500)
        let cutOffset = 1_200
        let suffixAfterCut = payload.count - cutOffset + 1
        let filler = String(repeating: "S", count: maxChars - suffixAfterCut)
        let source = prefix + payload + "\u{0007}" + filler
        let truncated = policy.truncatedScrollback(source)
        #expect(truncated?.hasPrefix("S") == true)
        #expect(truncated?.contains("\u{0007}") == false)
    }

    /// A completed OSC before the cut does not swallow the visible tail.
    @Test func completedOSCBeforeTheCutPreservesVisibleOutput() {
        let maxChars = SessionScrollbackPersistencePolicy.sessionSnapshotMaxCharacters
        let completedOSC = "\u{001B}]2;" + String(repeating: "T", count: 1_500) + "\u{0007}"
        let visibleBeforeBEL = "visible-before-bell"
        let visibleAfterBEL = "visible-after-bell"
        let cutInsideVisibleOffset = 3
        let suffixFromCut =
            visibleBeforeBEL.count - cutInsideVisibleOffset
            + 1
            + visibleAfterBEL.count
        let filler = String(repeating: "F", count: maxChars - suffixFromCut)
        let source =
            completedOSC
            + visibleBeforeBEL
            + "\u{0007}"
            + visibleAfterBEL
            + filler
        let truncated = policy.truncatedScrollback(source)
        #expect(truncated?.hasPrefix(String(visibleBeforeBEL.dropFirst(cutInsideVisibleOffset))) == true)
        #expect(truncated?.contains("\u{0007}" + visibleAfterBEL) == true)
    }

    /// A distant cut after a completed OSC keeps the plain output.
    @Test func distantCutAfterACompletedOSCPreservesPlainOutput() {
        let maxChars = SessionScrollbackPersistencePolicy.sessionSnapshotMaxCharacters
        let completedOSC = "\u{001B}]2;" + String(repeating: "T", count: 1_500) + "\u{0007}"
        let plainOutput = String(repeating: "P", count: 1_500)
        let cutInsidePlainOffset = 1_200
        let visibleAfterCut = plainOutput.count - cutInsidePlainOffset
        let trailingBEL = "\u{0007}"
        let trailingOutput = "after-bell"
        let filler = String(
            repeating: "F",
            count: maxChars - visibleAfterCut - trailingBEL.count - trailingOutput.count
        )
        let source = completedOSC + plainOutput + trailingBEL + trailingOutput + filler
        let truncated = policy.truncatedScrollback(source)
        #expect(truncated?.hasPrefix(String(plainOutput.dropFirst(cutInsidePlainOffset))) == true)
        #expect(truncated?.contains(trailingBEL + trailingOutput) == true)
    }

    /// An unterminated sequence does not drop real output past the scan budget.
    @Test func malformedANSIStringScanKeepsDistantOutput() {
        let maxChars = SessionScrollbackPersistencePolicy.sessionSnapshotMaxCharacters
        let malformed = "\u{001B}]0;unterminated-title"
        let cutOffset = 8
        let realOutput = String(repeating: "R", count: 1_500)
        let suffixCount = malformed.count - cutOffset + realOutput.count + 1
        let filler = String(repeating: "F", count: maxChars - suffixCount)
        let source = malformed + realOutput + "\u{0007}" + filler
        let truncated = policy.truncatedScrollback(source)
        #expect(truncated?.contains(realOutput) == true)
    }
}

import Foundation
import Testing
@testable import CmuxMobileDiff

/// The Mac diff viewer's Next / Previous Hunk and Search on the phone's file diff.
@Suite struct DiffNavigationTests {
    private func lines(_ kinds: String, texts: [String]? = nil) -> [DiffLine] {
        kinds.enumerated().map { offset, kind in
            let k: DiffLine.Kind = kind == "+" ? .added : kind == "-" ? .removed : .context
            return DiffLine(kind: k, oldNumber: offset + 1, newNumber: offset + 1, text: texts?[offset] ?? "line \(offset)")
        }
    }

    @Test func hunksStartAtEachRunOfChanges() {
        let file = lines("  -+  + -")
        #expect(DiffNavigation.changeStarts(file) == [2, 6, 8])
        #expect(DiffNavigation.step([2, 6, 8], from: nil, forward: true) == 2)
        #expect(DiffNavigation.step([2, 6, 8], from: 2, forward: true) == 6)
        #expect(DiffNavigation.step([2, 6, 8], from: 8, forward: true) == nil)
        #expect(DiffNavigation.step([2, 6, 8], from: 6, forward: false) == 2)
        #expect(DiffNavigation.step([2, 6, 8], from: 2, forward: false) == nil)
        #expect(DiffNavigation.step([2, 6, 8], from: nil, forward: false) == nil)
    }

    @Test func aGapStartsANewHunk() {
        var file = lines("+ +")
        file[1] = DiffLine(kind: .context, oldNumber: nil, newNumber: nil, text: "", isGap: true)
        #expect(DiffNavigation.changeStarts(file) == [0, 2])
    }

    /// Toggling Hide Whitespace keeps Next / Previous Hunk on the same change: the current
    /// hunk's index follows the line, so Next goes to the later hunk, never back.
    @Test func hideWhitespaceKeepsTheCurrentHunk() {
        // 0 ctx, 1-3 whitespace-only additions, 4 ctx, 5 "+a", 6 ctx, 7 "+b", 8 ctx.
        let file = lines("     + + ", texts: ["c0", "  ", " ", "\t", "c4", "a", "c6", "b", "c8"])
            .enumerated().map { offset, line in
                var line = line
                if (1...3).contains(offset) { line.kind = .added }
                return line
            }
        let shown = DiffNavigation.visibleLines(file, hideWhitespace: false)
        let hidden = DiffNavigation.visibleLines(file, hideWhitespace: true)
        #expect(hidden.map(\.text) == ["c0", "c4", "a", "c6", "b", "c8"])

        // On "+a" (line 5 of the whole file), turn Hide Whitespace on.
        #expect(DiffNavigation.changeStarts(shown) == [1, 5, 7])
        let onA = DiffNavigation.remap(5, from: shown, to: hidden)
        #expect(onA == 2)
        #expect(DiffNavigation.step(DiffNavigation.changeStarts(hidden), from: onA, forward: true) == 4)
        #expect(DiffNavigation.step(DiffNavigation.changeStarts(hidden), from: onA, forward: false) == nil)

        // On "+b" (line 4 while hidden), turn it off again.
        let onB = DiffNavigation.remap(4, from: hidden, to: shown)
        #expect(onB == 7)
        #expect(DiffNavigation.step(DiffNavigation.changeStarts(shown), from: onB, forward: true) == nil)
        #expect(DiffNavigation.step(DiffNavigation.changeStarts(shown), from: onB, forward: false) == 5)

        // A current line that the filter hides maps to the line before it, so Next goes on
        // to the next change and Previous to the one before.
        let onBlank = DiffNavigation.remap(1, from: shown, to: hidden)
        #expect(onBlank == 0)
        #expect(DiffNavigation.step(DiffNavigation.changeStarts(hidden), from: onBlank, forward: true) == 2)
        #expect(DiffNavigation.remap(nil, from: shown, to: hidden) == nil)
    }

    @Test func searchFindsLinesAndRanges() {
        let file = lines("   ", texts: ["let Café = 1", "nothing", "café café"])
        #expect(DiffNavigation.matches("cafe", in: file) == [0, 2])
        #expect(DiffNavigation.matches("  ", in: file).isEmpty)
        #expect(DiffNavigation.ranges(of: "CAFE", in: "café café") == [0..<4, 5..<9])
        #expect(DiffNavigation.ranges(of: "", in: "abc").isEmpty)
        #expect(DiffNavigation.reveal(1, lineCount: 10) == 0...4)
        #expect(DiffNavigation.reveal(9, lineCount: 10) == 6...9)
    }
}

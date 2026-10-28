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

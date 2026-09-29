import Foundation
import Testing
@testable import CmuxFileTree

/// Applies a diff the way `NSOutlineView` batch updates do: removals in old
/// coordinates, then insertions in new coordinates, in ascending order.
private func apply(_ diff: FileTreeChildrenDiff, old: [FileTreeEntry], new: [FileTreeEntry]) -> [FileTreeEntry] {
    var rows = old
    for index in diff.removed.reversed() {
        rows.remove(at: index)
    }
    for index in diff.inserted {
        rows.insert(new[index], at: index)
    }
    for index in diff.updated {
        rows[index] = new[index]
    }
    return rows
}

private func entry(_ name: String, size: Int64 = 0, directory: Bool = false) -> FileTreeEntry {
    FileTreeEntry(name: name, path: "/root/" + name, kind: directory ? .directory : .file, size: size)
}

@Suite struct FileTreeChildrenDiffTests {
    @Test func identicalListsProduceNoChanges() {
        let rows = (0..<10).map { entry("f\($0)") }
        #expect(FileTreeChildrenDiff(old: rows, new: rows).isEmpty)
    }

    @Test func insertAndRemoveKeepSurvivorsInPlace() {
        let old = ["a", "b", "c", "d"].map { entry($0) }
        let new = ["a", "c", "d", "e"].map { entry($0) }
        let diff = FileTreeChildrenDiff(old: old, new: new)
        #expect(diff.removed == IndexSet(integer: 1))
        #expect(diff.inserted == IndexSet(integer: 3))
        #expect(diff.moved.isEmpty)
        #expect(apply(diff, old: old, new: new) == new)
    }

    @Test func metadataChangeIsAnUpdateNotAMove() {
        let old = [entry("a", size: 1), entry("b", size: 1)]
        let new = [entry("a", size: 1), entry("b", size: 2)]
        let diff = FileTreeChildrenDiff(old: old, new: new)
        #expect(diff.structuralChangeCount == 0)
        #expect(diff.updated == IndexSet(integer: 1))
        #expect(apply(diff, old: old, new: new) == new)
    }

    @Test func reorderMovesTheFewestRows() {
        let old = ["a", "b", "c", "d", "e"].map { entry($0) }
        let new = ["b", "c", "d", "e", "a"].map { entry($0) }
        let diff = FileTreeChildrenDiff(old: old, new: new)
        #expect(diff.moved == ["/root/a"])
        #expect(diff.structuralChangeCount == 2)
        #expect(apply(diff, old: old, new: new) == new)
    }

    @Test(arguments: 0..<200)
    func randomEditsRoundTrip(seed: Int) {
        var generator = SeededGenerator(seed: UInt64(seed))
        let universe = (0..<40).map { entry("n\($0)", size: Int64($0)) }
        let old = universe.filter { _ in Bool.random(using: &generator) }.shuffled(using: &generator)
        var new = universe.filter { _ in Bool.random(using: &generator) }.shuffled(using: &generator)
        if !new.isEmpty, Bool.random(using: &generator) {
            let index = Int.random(in: 0..<new.count, using: &generator)
            new[index] = FileTreeEntry(name: new[index].name, path: new[index].path, kind: .file, size: 999)
        }
        let diff = FileTreeChildrenDiff(old: old, new: new)
        #expect(apply(diff, old: old, new: new) == new)
    }
}

/// Deterministic SplitMix64 so the fuzz cases are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

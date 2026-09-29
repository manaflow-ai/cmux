import Foundation
import CmuxAcpmux

/// The difference between two row snapshots, found by matching a common prefix and
/// suffix of row ids. Appends, streaming updates, and prepends are all one contiguous
/// replaced range, so this O(n) scan is exact for the transcript's change patterns.
struct AcpmuxTranscriptDiff {
    let removed: Range<Int>
    let inserted: Range<Int>
    /// New-snapshot indexes whose content or group position changed.
    let updated: IndexSet

    init(
        old: [TranscriptRow],
        new: [TranscriptRow],
        oldPositions: [AcpmuxRowGroupPosition],
        newPositions: [AcpmuxRowGroupPosition]
    ) {
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix].id == new[prefix].id { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix].id == new[new.count - 1 - suffix].id {
            suffix += 1
        }
        removed = prefix..<(old.count - suffix)
        inserted = prefix..<(new.count - suffix)
        var updated = IndexSet()
        for index in 0..<prefix where old[index].version != new[index].version || oldPositions[index] != newPositions[index] {
            updated.insert(index)
        }
        for offset in 0..<suffix {
            let oldIndex = old.count - 1 - offset
            let newIndex = new.count - 1 - offset
            if old[oldIndex].version != new[newIndex].version || oldPositions[oldIndex] != newPositions[newIndex] {
                updated.insert(newIndex)
            }
        }
        self.updated = updated
    }

    var isEmpty: Bool { removed.isEmpty && inserted.isEmpty && updated.isEmpty }
}

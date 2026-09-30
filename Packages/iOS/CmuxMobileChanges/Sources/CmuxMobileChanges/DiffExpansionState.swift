/// Revealed unchanged line ranges, keyed by their stable diff-gap identity.
struct DiffExpansionState: Sendable, Equatable {
    static let stepLineCount = 100
    static let shortRunThreshold = 120

    private(set) var revealedRangesByGapID: [Int: [Range<Int>]] = [:]

    func revealedRanges(for gapID: Int) -> [Range<Int>] {
        revealedRangesByGapID[gapID] ?? []
    }

    func hiddenRanges(in gap: DiffGap) -> [Range<Int>] {
        guard let gapRange = gap.newLineRange else { return [] }
        var hiddenRanges: [Range<Int>] = []
        var cursor = gapRange.lowerBound
        for revealed in revealedRanges(for: gap.id) {
            let clippedLower = max(gapRange.lowerBound, revealed.lowerBound)
            let clippedUpper = min(gapRange.upperBound, revealed.upperBound)
            guard clippedLower < clippedUpper else { continue }
            if cursor < clippedLower {
                hiddenRanges.append(cursor..<clippedLower)
            }
            cursor = max(cursor, clippedUpper)
        }
        if cursor < gapRange.upperBound {
            hiddenRanges.append(cursor..<gapRange.upperBound)
        }
        return hiddenRanges
    }

    mutating func reveal(
        in gap: DiffGap,
        direction: DiffExpansionDirection,
        preferredHiddenRange: Range<Int>? = nil
    ) {
        let hiddenRanges = hiddenRanges(in: gap)
        let hiddenRange = preferredHiddenRange.flatMap { preferred in
            hiddenRanges.first(where: { $0 == preferred })
        } ?? (direction == .down ? hiddenRanges.first : hiddenRanges.last)
        guard let hiddenRange else { return }

        let revealCount = hiddenRange.count <= Self.shortRunThreshold
            ? hiddenRange.count
            : min(Self.stepLineCount, hiddenRange.count)
        let revealed: Range<Int>
        switch direction {
        case .down:
            revealed = hiddenRange.lowerBound..<(hiddenRange.lowerBound + revealCount)
        case .up:
            revealed = (hiddenRange.upperBound - revealCount)..<hiddenRange.upperBound
        }
        revealedRangesByGapID[gap.id] = Self.merged(
            revealedRanges(for: gap.id) + [revealed]
        )
    }

    private static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        let sorted = ranges.filter { !$0.isEmpty }.sorted { lhs, rhs in
            lhs.lowerBound == rhs.lowerBound
                ? lhs.upperBound < rhs.upperBound
                : lhs.lowerBound < rhs.lowerBound
        }
        guard var current = sorted.first else { return [] }
        var result: [Range<Int>] = []
        for range in sorted.dropFirst() {
            if range.lowerBound <= current.upperBound {
                current = current.lowerBound..<max(current.upperBound, range.upperBound)
            } else {
                result.append(current)
                current = range
            }
        }
        result.append(current)
        return result
    }
}

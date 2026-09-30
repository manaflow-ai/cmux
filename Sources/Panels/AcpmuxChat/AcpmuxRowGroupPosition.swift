import CmuxAcpmux

/// Where a row sits in a run of consecutive bubbles from the same speaker.
struct AcpmuxRowGroupPosition: Hashable {
    let isFirst: Bool
    let isLast: Bool

    static let standalone = AcpmuxRowGroupPosition(isFirst: true, isLast: true)

    /// Positions for every row, derived from neighbors' bubble roles.
    static func compute(_ rows: [TranscriptRow]) -> [AcpmuxRowGroupPosition] {
        rows.indices.map { index in
            guard let role = rows[index].bubbleRole else { return .standalone }
            let previous = index > 0 ? rows[index - 1].bubbleRole : nil
            let next = index + 1 < rows.count ? rows[index + 1].bubbleRole : nil
            return AcpmuxRowGroupPosition(isFirst: previous != role, isLast: next != role)
        }
    }
}

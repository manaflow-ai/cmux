/// Preserves the opening user request and the latest dialogue within a bounded prompt.
public struct TailPreservingConversationCompactor: ConversationCompacting {
    private static let framingReserve = 512
    private static let turnFramingBytes = 16
    private let byteClipper = UTF8ByteClipper()

    /// Creates a tail-preserving compactor.
    public init() {}

    /// Keeps the opening user request and as much recent dialogue as fits.
    /// - Parameters:
    ///   - turns: Source turns in chronological order.
    ///   - policy: Size and role policy for the handoff.
    /// - Returns: The retained turns and compaction statistics.
    public func compact(
        _ turns: [ConversationTurn],
        policy: ConversationTransferPolicy
    ) -> ConversationCompaction {
        let eligible = turns.filter { policy.includes($0.role) && !$0.text.isEmpty }
        guard !eligible.isEmpty else {
            return ConversationCompaction(
                turns: [],
                omittedTurnCount: 0,
                shortenedTurnCount: 0
            )
        }

        let bodyBudget = max(256, policy.maximumBytes - Self.framingReserve)
        if fits(eligible, within: bodyBudget) {
            return ConversationCompaction(
                turns: renumbered(eligible),
                omittedTurnCount: 0,
                shortenedTurnCount: 0
            )
        }

        let firstUserIndex = eligible.firstIndex { $0.role == .user }
        let reservedHead = firstUserIndex.map { _ in
            min(policy.initialUserByteLimit, max(256, bodyBudget / 4))
        } ?? 0
        let tailBudget = max(128, bodyBudget - reservedHead - 96)

        var tail: [(index: Int, turn: ConversationTurn)] = []
        var remaining = tailBudget
        var shortenedCount = 0
        for index in eligible.indices.reversed() where index != firstUserIndex {
            let turn = eligible[index]
            let cost = estimatedByteCount(of: turn)
            if cost <= remaining {
                tail.append((index, turn))
                remaining -= cost
                continue
            }
            if tail.isEmpty, remaining > Self.turnFramingBytes {
                tail.append((
                    index,
                    clipped(turn, byteLimit: remaining - Self.turnFramingBytes)
                ))
                shortenedCount += 1
            }
            break
        }
        tail.reverse()

        var kept: [(index: Int, turn: ConversationTurn)] = []
        if let firstUserIndex {
            let firstUser = eligible[firstUserIndex]
            let limit = max(1, reservedHead - Self.turnFramingBytes)
            let clippedFirst = clipped(firstUser, byteLimit: limit)
            if clippedFirst.text != firstUser.text {
                shortenedCount += 1
            }
            kept.append((firstUserIndex, clippedFirst))
        }
        kept.append(contentsOf: tail)
        kept.sort { $0.index < $1.index }

        if kept.isEmpty, let last = eligible.last {
            kept = [(
                eligible.count - 1,
                clipped(last, byteLimit: bodyBudget - Self.turnFramingBytes)
            )]
            shortenedCount = 1
        }

        let uniqueIndices = Set(kept.map(\.index))
        return ConversationCompaction(
            turns: renumbered(kept.map(\.turn)),
            omittedTurnCount: max(0, eligible.count - uniqueIndices.count),
            shortenedTurnCount: shortenedCount
        )
    }

    private func fits(_ turns: [ConversationTurn], within byteLimit: Int) -> Bool {
        var remaining = byteLimit
        for turn in turns {
            let cost = estimatedByteCount(of: turn)
            guard cost <= remaining else { return false }
            remaining -= cost
        }
        return true
    }

    private func estimatedByteCount(of turn: ConversationTurn) -> Int {
        let (cost, overflow) = turn.text.utf8.count.addingReportingOverflow(Self.turnFramingBytes)
        return overflow ? .max : cost
    }

    private func clipped(_ turn: ConversationTurn, byteLimit: Int) -> ConversationTurn {
        let clippedText = byteClipper.clipped(turn.text, maximumBytes: byteLimit)
        guard clippedText != turn.text else { return turn }
        return ConversationTurn(
            id: turn.id,
            role: turn.role,
            text: clippedText
        )
    }

    private func renumbered(_ turns: [ConversationTurn]) -> [ConversationTurn] {
        turns.enumerated().map { index, turn in
            ConversationTurn(id: index, role: turn.role, text: turn.text)
        }
    }
}

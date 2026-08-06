/// Preserves the opening user request and the latest dialogue within a bounded prompt.
public struct TailPreservingConversationCompactor: ConversationCompacting {
    private static let framingReserve = 512
    private let byteClipper = UTF8ByteClipper()

    /// Creates a tail-preserving compactor.
    public init() {}

    /// Keeps the opening user request and as much recent dialogue as fits.
    /// - Parameters:
    ///   - turns: Source turns in chronological order.
    ///   - policy: Size and role policy for the handoff.
    ///   - formattedByteCount: Safe formatted byte-cost bound for each retained turn.
    /// - Returns: The retained turns and compaction statistics.
    public func compact(
        _ turns: [ConversationTurn],
        policy: ConversationTransferPolicy,
        formattedByteCount: @Sendable (ConversationTurn) -> Int
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
        if fits(
            eligible,
            within: bodyBudget,
            formattedByteCount: formattedByteCount
        ) {
            return ConversationCompaction(
                turns: renumbered(eligible),
                omittedTurnCount: 0,
                shortenedTurnCount: 0
            )
        }

        if eligible.count == 1, let onlyTurn = eligible.first {
            let framingByteCount = framingByteCount(
                of: onlyTurn,
                formattedByteCount: formattedByteCount
            )
            let clippedTurn = clipped(
                onlyTurn,
                byteLimit: max(1, bodyBudget - framingByteCount)
            )
            return ConversationCompaction(
                turns: renumbered([clippedTurn]),
                omittedTurnCount: 0,
                shortenedTurnCount: clippedTurn.text == onlyTurn.text ? 0 : 1
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
            let cost = formattedByteCount(turn)
            if cost <= remaining {
                tail.append((index, turn))
                remaining -= cost
                continue
            }
            let framingByteCount = framingByteCount(
                of: turn,
                formattedByteCount: formattedByteCount
            )
            if tail.isEmpty, remaining > framingByteCount {
                tail.append((
                    index,
                    clipped(turn, byteLimit: remaining - framingByteCount)
                ))
                shortenedCount += 1
            }
            break
        }
        tail.reverse()

        var kept: [(index: Int, turn: ConversationTurn)] = []
        if let firstUserIndex {
            let firstUser = eligible[firstUserIndex]
            let framingByteCount = framingByteCount(
                of: firstUser,
                formattedByteCount: formattedByteCount
            )
            let limit = max(1, reservedHead - framingByteCount)
            let clippedFirst = clipped(firstUser, byteLimit: limit)
            if clippedFirst.text != firstUser.text {
                shortenedCount += 1
            }
            kept.append((firstUserIndex, clippedFirst))
        }
        kept.append(contentsOf: tail)
        kept.sort { $0.index < $1.index }

        if kept.isEmpty, let last = eligible.last {
            let framingByteCount = framingByteCount(
                of: last,
                formattedByteCount: formattedByteCount
            )
            kept = [(
                eligible.count - 1,
                clipped(last, byteLimit: max(1, bodyBudget - framingByteCount))
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

    private func fits(
        _ turns: [ConversationTurn],
        within byteLimit: Int,
        formattedByteCount: @Sendable (ConversationTurn) -> Int
    ) -> Bool {
        var remaining = byteLimit
        for turn in turns {
            let cost = formattedByteCount(turn)
            guard cost <= remaining else { return false }
            remaining -= cost
        }
        return true
    }

    private func framingByteCount(
        of turn: ConversationTurn,
        formattedByteCount: @Sendable (ConversationTurn) -> Int
    ) -> Int {
        max(0, formattedByteCount(turn) - turn.text.utf8.count)
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

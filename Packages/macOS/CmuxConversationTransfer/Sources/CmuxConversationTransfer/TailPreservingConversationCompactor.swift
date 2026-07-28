/// Preserves the opening user request and the latest dialogue within a bounded prompt.
public struct TailPreservingConversationCompactor: ConversationCompacting {
    private static let framingReserve = 512
    private static let turnFramingCharacters = 16

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

        let bodyBudget = max(256, policy.maximumCharacters - Self.framingReserve)
        if estimatedLength(of: eligible) <= bodyBudget {
            return ConversationCompaction(
                turns: renumbered(eligible),
                omittedTurnCount: 0,
                shortenedTurnCount: 0
            )
        }

        let firstUserIndex = eligible.firstIndex { $0.role == .user }
        let reservedHead = firstUserIndex.map { _ in
            min(policy.initialUserCharacterLimit, max(256, bodyBudget / 4))
        } ?? 0
        let tailBudget = max(128, bodyBudget - reservedHead - 96)

        var tail: [(index: Int, turn: ConversationTurn)] = []
        var remaining = tailBudget
        var shortenedCount = 0
        for index in eligible.indices.reversed() where index != firstUserIndex {
            let turn = eligible[index]
            let cost = estimatedLength(of: turn)
            if cost <= remaining {
                tail.append((index, turn))
                remaining -= cost
                continue
            }
            if tail.isEmpty, remaining > Self.turnFramingCharacters {
                tail.append((
                    index,
                    clipped(turn, characterLimit: remaining - Self.turnFramingCharacters)
                ))
                shortenedCount += 1
            }
            break
        }
        tail.reverse()

        var kept: [(index: Int, turn: ConversationTurn)] = []
        if let firstUserIndex {
            let firstUser = eligible[firstUserIndex]
            let limit = max(1, reservedHead - Self.turnFramingCharacters)
            let clippedFirst = clipped(firstUser, characterLimit: limit)
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
                clipped(last, characterLimit: bodyBudget - Self.turnFramingCharacters)
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

    private func estimatedLength(of turns: [ConversationTurn]) -> Int {
        turns.reduce(0) { $0 + estimatedLength(of: $1) }
    }

    private func estimatedLength(of turn: ConversationTurn) -> Int {
        turn.text.count + Self.turnFramingCharacters
    }

    private func clipped(_ turn: ConversationTurn, characterLimit: Int) -> ConversationTurn {
        guard characterLimit > 0, turn.text.count > characterLimit else { return turn }
        let marker = "\n…\n"
        let available = max(1, characterLimit - marker.count)
        let headCount = available / 2
        let tailCount = available - headCount
        let headEnd = turn.text.index(turn.text.startIndex, offsetBy: headCount)
        let tailStart = turn.text.index(turn.text.endIndex, offsetBy: -tailCount)
        return ConversationTurn(
            id: turn.id,
            role: turn.role,
            text: String(turn.text[..<headEnd]) + marker + String(turn.text[tailStart...])
        )
    }

    private func renumbered(_ turns: [ConversationTurn]) -> [ConversationTurn] {
        turns.enumerated().map { index, turn in
            ConversationTurn(id: index, role: turn.role, text: turn.text)
        }
    }
}

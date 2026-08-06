import CmuxConversationTransfer
import Foundation

/// Selects which parsed transcript turns remain in memory.
enum SessionTranscriptRetention: Equatable, Sendable {
    /// Keep the first `limit` turns. Used by the Sessions preview.
    case prefix(Int)
    /// Keep the opening user request and the most recent `limit` turns.
    case openingUserAndLatest(Int)
    /// Keep transfer context within both a turn-count and aggregate UTF-8 byte ceiling.
    case transferOpeningUserAndLatest(turnLimit: Int, textByteLimit: Int)

    var limit: Int {
        switch self {
        case .prefix(let limit), .openingUserAndLatest(let limit):
            max(1, limit)
        case .transferOpeningUserAndLatest(let turnLimit, _):
            max(1, turnLimit)
        }
    }

    var keepsLatestTurns: Bool {
        switch self {
        case .openingUserAndLatest, .transferOpeningUserAndLatest:
            true
        case .prefix:
            false
        }
    }

    var textByteLimit: Int? {
        guard case .transferOpeningUserAndLatest(_, let textByteLimit) = self else {
            return nil
        }
        return max(1, textByteLimit)
    }

    var requiresCompleteLatestScan: Bool {
        if case .transferOpeningUserAndLatest = self {
            return true
        }
        return false
    }

    func includes(_ role: SessionTranscriptRole) -> Bool {
        guard case .transferOpeningUserAndLatest = self else { return true }
        return role == .user || role == .assistant
    }

    func bounded(_ turn: SessionTranscriptTurn) -> SessionTranscriptTurn {
        guard let textByteLimit else { return turn }
        let text = UTF8ByteClipper().clipped(
            turn.text,
            maximumBytes: max(0, textByteLimit - 2)
        )
        return SessionTranscriptTurn(id: turn.id, role: turn.role, text: text)
    }

    func retainedByteCost(of turn: SessionTranscriptTurn) -> Int {
        let (cost, overflow) = turn.text.utf8.count.addingReportingOverflow(2)
        return overflow ? .max : cost
    }

    func boundedTurnsPreservingOpeningAndLatest(
        _ turns: [SessionTranscriptTurn]
    ) -> [SessionTranscriptTurn] {
        let includedTurns = turns.filter { includes($0.role) }
        guard let textByteLimit else { return includedTurns }
        guard !includedTurns.isEmpty else { return [] }
        var fitRemainingBytes = textByteLimit
        let allTurnsFit = includedTurns.allSatisfy { turn in
            let byteCost = retainedByteCost(of: turn)
            guard byteCost <= fitRemainingBytes else { return false }
            fitRemainingBytes -= byteCost
            return true
        }
        if allTurnsFit { return includedTurns }

        let firstUserIndex = includedTurns.firstIndex { $0.role == .user }
        var retained: [(index: Int, turn: SessionTranscriptTurn)] = []
        var remainingBytes = textByteLimit
        if let firstUserIndex {
            let openingLimit = max(
                0,
                min(remainingBytes, max(1, textByteLimit / 4)) - 2
            )
            let opening = clipped(includedTurns[firstUserIndex], maximumBytes: openingLimit)
            retained.append((firstUserIndex, opening))
            remainingBytes -= retainedByteCost(of: opening)
        }

        var tail: [(index: Int, turn: SessionTranscriptTurn)] = []
        for index in includedTurns.indices.reversed() where index != firstUserIndex && remainingBytes > 2 {
            let turn = includedTurns[index]
            let byteCost = retainedByteCost(of: turn)
            if byteCost <= remainingBytes {
                tail.append((index, turn))
                remainingBytes -= byteCost
                continue
            }
            if tail.isEmpty {
                tail.append((index, clipped(turn, maximumBytes: remainingBytes - 2)))
            }
            break
        }
        retained.append(contentsOf: tail)
        retained.sort { $0.index < $1.index }
        return retained.map(\.turn)
    }

    private func clipped(
        _ turn: SessionTranscriptTurn,
        maximumBytes: Int
    ) -> SessionTranscriptTurn {
        let text = UTF8ByteClipper().clipped(turn.text, maximumBytes: maximumBytes)
        return SessionTranscriptTurn(id: turn.id, role: turn.role, text: text)
    }
}

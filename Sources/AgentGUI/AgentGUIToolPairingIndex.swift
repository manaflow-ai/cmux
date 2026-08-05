import CmuxAgentReplica
import Foundation

struct AgentGUIToolPairingIndex {
    private var runningSeqsBySignature: [String: [EntrySeq]] = [:]

    mutating func normalize(_ entry: EntrySnapshot) -> EntrySnapshot {
        guard let pairable = pairableState(for: entry.content.payload) else { return entry }
        if pairable.isRunning {
            runningSeqsBySignature[pairable.signature, default: []].append(entry.seq)
            return entry
        }
        guard var seqs = runningSeqsBySignature[pairable.signature], !seqs.isEmpty else {
            return entry
        }
        let originalSeq = seqs.removeFirst()
        runningSeqsBySignature[pairable.signature] = seqs.isEmpty ? nil : seqs
        return EntrySnapshot(
            journalID: entry.journalID,
            seq: originalSeq,
            kind: entry.kind,
            content: entry.content,
            version: entry.version,
            timestampMilliseconds: entry.timestampMilliseconds
        )
    }

    mutating func reset() {
        runningSeqsBySignature.removeAll()
    }

    private func signature(for payload: ToolRunPayload) -> String {
        if let toolCallID = payload.toolCallID, !toolCallID.isEmpty {
            return "id\u{1f}\(toolCallID)"
        }
        return [
            payload.toolName,
            payload.argumentSummary,
            payload.isTerminal ? "terminal" : "tool"
        ].joined(separator: "\u{1f}")
    }

    private func pairableState(for payload: EntryPayload) -> (signature: String, isRunning: Bool)? {
        switch payload {
        case .toolRun(let tool):
            return (signature(for: tool), tool.isRunning)
        case .fileChange(let file):
            let signature: String
            if let toolCallID = file.toolCallID, !toolCallID.isEmpty {
                signature = "id\u{1f}\(toolCallID)"
            } else {
                signature = ["file", file.changeKind.rawValue, file.path].joined(separator: "\u{1f}")
            }
            return (signature, file.resultSummary == nil)
        default:
            return nil
        }
    }
}

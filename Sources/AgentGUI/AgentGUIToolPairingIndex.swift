import CmuxAgentReplica
import Foundation

struct AgentGUIToolPairingIndex {
    private var runningSeqsBySignature: [String: [EntrySeq]] = [:]

    mutating func normalize(_ entry: EntrySnapshot) -> EntrySnapshot {
        guard case .toolRun(let payload) = entry.content.payload else {
            return entry
        }
        let signature = signature(for: payload)
        if payload.isRunning {
            runningSeqsBySignature[signature, default: []].append(entry.seq)
            return entry
        }
        guard var seqs = runningSeqsBySignature[signature], !seqs.isEmpty else {
            return entry
        }
        let originalSeq = seqs.removeFirst()
        runningSeqsBySignature[signature] = seqs.isEmpty ? nil : seqs
        return EntrySnapshot(
            journalID: entry.journalID,
            seq: originalSeq,
            kind: entry.kind,
            content: entry.content,
            version: entry.version
        )
    }

    mutating func reset() {
        runningSeqsBySignature.removeAll()
    }

    private func signature(for payload: ToolRunPayload) -> String {
        [
            payload.toolName,
            payload.argumentSummary,
            payload.isTerminal ? "terminal" : "tool"
        ].joined(separator: "\u{1f}")
    }
}

import CmuxAgentReplica
import Foundation

struct TranscriptDecodeAccumulator {
    private(set) var entries: [EntrySnapshot]
    private(set) var payloads: [EntryCoordinate: DecodedEntryPayload]
    private(set) var unknownKindCounts: [String: Int]
    private(set) var cliVersion: String?

    init() {
        self.entries = []
        self.payloads = [:]
        self.unknownKindCounts = [:]
        self.cliVersion = nil
    }

    mutating func emit(
        kind: EntryKind,
        summary: String,
        raw: String?,
        journalID: JournalID,
        lineIndex: Int
    ) {
        let payload = DecodedEntryPayload(
            contentHash: stableHash(kind.rawValue + "|" + summary + "|" + (raw ?? "")),
            summary: summary,
            raw: raw
        )
        let seq = EntrySeq(rawValue: lineIndex)
        entries.append(EntrySnapshot(
            journalID: journalID,
            seq: seq,
            kind: kind,
            content: EntryContent(contentHash: payload.contentHash),
            version: EntityVersion(rawValue: 1)
        ))
        payloads[EntryCoordinate(journalID: journalID, seq: seq)] = payload
    }

    mutating func countUnknown(_ rawKind: String) {
        unknownKindCounts[rawKind, default: 0] += 1
    }

    mutating func recordCLIVersion(_ version: String) {
        cliVersion = version
    }

    func batch() -> TranscriptDecodeBatch {
        TranscriptDecodeBatch(
            entries: entries,
            payloads: payloads,
            diagnostics: TranscriptDecoderDiagnostics(unknownKindCounts: unknownKindCounts, cliVersion: cliVersion)
        )
    }

    private func stableHash(_ value: String) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(truncatingIfNeeded: hash)
    }
}

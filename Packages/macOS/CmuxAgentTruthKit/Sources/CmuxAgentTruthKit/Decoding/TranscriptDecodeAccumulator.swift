import CmuxAgentReplica
import Foundation

struct TranscriptDecodeAccumulator {
    private(set) var entries: [EntrySnapshot]
    private(set) var payloads: [EntryCoordinate: DecodedEntryPayload]
    private(set) var unknownKindCounts: [String: Int]
    private(set) var modeledKindCounts: [String: Int]
    private(set) var duplicateStreamCounts: [String: Int]
    private(set) var bookkeepingKindCounts: [String: Int]
    private(set) var cliVersion: String?
    private(set) var phaseFacts: [PhaseFact]
    private(set) var turnContextFacts: [TurnContextFact]
    private(set) var sawApiError: Bool
    private(set) var sensitiveSessionTitles: [SensitiveSessionTitleFact]

    init() {
        self.entries = []
        self.payloads = [:]
        self.unknownKindCounts = [:]
        self.modeledKindCounts = [:]
        self.duplicateStreamCounts = [:]
        self.bookkeepingKindCounts = [:]
        self.cliVersion = nil
        self.phaseFacts = []
        self.turnContextFacts = []
        self.sawApiError = false
        self.sensitiveSessionTitles = []
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

    mutating func countModeled(_ rawKind: String) {
        modeledKindCounts[rawKind, default: 0] += 1
    }

    mutating func countDuplicateStream(_ rawKind: String) {
        duplicateStreamCounts[rawKind, default: 0] += 1
    }

    mutating func countBookkeeping(_ rawKind: String) {
        bookkeepingKindCounts[rawKind, default: 0] += 1
    }

    mutating func recordCLIVersion(_ version: String) {
        cliVersion = version
    }

    mutating func recordPhaseFact(_ fact: PhaseFact) {
        phaseFacts.append(fact)
    }

    mutating func recordTurnContextFact(_ fact: TurnContextFact) {
        turnContextFacts.append(fact)
    }

    mutating func recordAPIError() {
        sawApiError = true
    }

    mutating func recordSensitiveSessionTitle(_ fact: SensitiveSessionTitleFact) {
        sensitiveSessionTitles.append(fact)
    }

    func batch() -> TranscriptDecodeBatch {
        TranscriptDecodeBatch(
            entries: entries,
            payloads: payloads,
            diagnostics: TranscriptDecoderDiagnostics(
                unknownKindCounts: unknownKindCounts,
                modeledKindCounts: modeledKindCounts,
                duplicateStreamCounts: duplicateStreamCounts,
                bookkeepingKindCounts: bookkeepingKindCounts,
                cliVersion: cliVersion,
                phaseFacts: phaseFacts,
                turnContextFacts: turnContextFacts,
                sawApiError: sawApiError,
                sensitiveSessionTitles: sensitiveSessionTitles
            )
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

import CmuxAgentReplica
import Foundation

struct TranscriptDecodeAccumulator {
    // Keep a single source record within the GUI entries transport's hard page
    // limit. This lets callers preserve the record boundary without returning
    // an over-limit page, while reserving the final row for a visible
    // truncation diagnostic.
    static let maxEntriesPerSourceRecord = 200

    private(set) var entries: [EntrySnapshot]
    private(set) var unknownKindCounts: [String: Int]
    private(set) var modeledKindCounts: [String: Int]
    private(set) var duplicateStreamCounts: [String: Int]
    private(set) var bookkeepingKindCounts: [String: Int]
    private(set) var cliVersion: String?
    private(set) var phaseFacts: [PhaseFact]
    private(set) var turnContextFacts: [TurnContextFact]
    private(set) var sawApiError: Bool
    private(set) var sensitiveSessionTitles: [SensitiveSessionTitleFact]
    private var currentTimestampMilliseconds: Int64?

    init() {
        self.entries = []
        self.unknownKindCounts = [:]
        self.modeledKindCounts = [:]
        self.duplicateStreamCounts = [:]
        self.bookkeepingKindCounts = [:]
        self.cliVersion = nil
        self.phaseFacts = []
        self.turnContextFacts = []
        self.sawApiError = false
        self.sensitiveSessionTitles = []
        self.currentTimestampMilliseconds = nil
    }

    mutating func beginSourceLine(timestampMilliseconds: Int64?) {
        currentTimestampMilliseconds = timestampMilliseconds
    }

    mutating func emit(
        payload: EntryPayload,
        journalID: JournalID,
        lineIndex: Int
    ) {
        let seq = EntrySeq(rawValue: lineIndex)
        entries.append(EntrySnapshot(
            journalID: journalID,
            seq: seq,
            kind: payload.kind,
            content: EntryContent(contentHash: payload.stableHash, payload: payload),
            version: EntityVersion(rawValue: 1),
            timestampMilliseconds: currentTimestampMilliseconds
        ))
    }

    /// Emits every user-visible block from one source record without losing
    /// source order. The first block retains the record's absolute byte
    /// offset; later blocks use successive byte positions inside that record.
    /// A valid JSON block occupies more than one byte, so these ordinals remain
    /// strictly before the next source record's byte offset.
    mutating func emit(
        payloads: [EntryPayload],
        journalID: JournalID,
        lineIndex: Int
    ) {
        let boundedPayloads: [EntryPayload]
        if payloads.count > Self.maxEntriesPerSourceRecord {
            let retainedCount = Self.maxEntriesPerSourceRecord - 1
            countUnknown("source_record_entries_truncated")
            boundedPayloads = Array(payloads.prefix(retainedCount)) + [
                .unknown(UnknownPayload(
                    rawKind: "source_record_entries_truncated",
                    summary: "Source record contains \(payloads.count) visible blocks; retained the first \(retainedCount)."
                )),
            ]
        } else {
            boundedPayloads = payloads
        }
        for (ordinal, payload) in boundedPayloads.enumerated() {
            emit(
                payload: payload,
                journalID: journalID,
                lineIndex: lineIndex + ordinal
            )
        }
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
}

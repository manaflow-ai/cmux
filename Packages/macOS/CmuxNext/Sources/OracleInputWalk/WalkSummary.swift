import CmuxNextInputModel

/// The run's summary: one JSON line on stdout.
struct WalkSummary: Codable {
    struct Failed: Codable {
        var seed: UInt64
        var signature: String
        var detail: String
        var actions: Int
        var journal: String
    }

    var seed: UInt64
    /// The planted driver bug (`--plant-fault`), if any.
    var fault: String?
    var walks: Int
    var stepsPerWalk: Int
    var steps: Int
    /// Walks whose journal was replayed with `InputReplay` (WalkConfig.exact).
    var replayedWalks: Int
    var failures: Int
    /// FNV-1a over every walk's digest in seed order: two runs of the same options give the same one.
    var digest: String
    var failed: [Failed]
}

struct WalkOutcome: Sendable {
    var seed: UInt64
    var exact: Bool
    /// FNV-1a of the whole walk's journal: two runs of one seed give the same digest.
    var digest: UInt64
    var failure: WalkFailure?
}

/// FNV-1a 64 over journal records.
struct JournalDigest {
    private(set) var value: UInt64 = 0xCBF2_9CE4_8422_2325

    mutating func add(_ text: String) {
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
    }

    mutating func add(_ entries: [InputJournalEntry]) {
        for entry in entries {
            guard case .attach(let record) = entry.kind else { continue }
            add("\(record.surface) \(record.event) \(record.link ?? -1) \(record.attempt ?? -1) \(record.bytes) ")
            add("\(record.phase) \(record.droppedBytes);")
        }
    }
}

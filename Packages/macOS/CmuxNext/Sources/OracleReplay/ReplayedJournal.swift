import CmuxNextInputModel

/// One journal and what replaying it on this build's reducers gave: `InputReplay(entries).run()`, the same call
/// and the same `Result` as `debug.replay`.
struct ReplayedJournal: Sendable {
    var journal: Journal
    var result: InputReplay.Result

    /// Replays `journal` and keeps what the report needs (its case, path, header and lines), not its entries.
    init(_ journal: Journal) {
        result = InputReplay(journal.entries).run()
        self.journal = journal
        self.journal.entries = []
    }

    var diverged: Bool { result.firstDivergence != nil }

    /// The receipt result: the recording is the reference, so a replay that differs from it is a Failure.
    var outcome: String { diverged ? "Failure" : "Pass" }

    /// diff.py's first divergence of this case (`compare_case`): side a is the recording, side b the replay.
    var first: FirstDivergence? {
        result.firstDivergence.map { FirstDivergence($0, line: journal.lines[$0.seq]) }
    }
}

/// diff.py's `first` object (`_divergence`): the step, its index, the checkpoint, the first differing pointer
/// and both sides' values there. A journal step is one entry: its index is the entry's `seq`.
struct FirstDivergence: Encodable, Sendable {
    /// A side's value: the recorded or replayed outcome text, or the invariants broken (none on the recording).
    enum Value: Encodable, Sendable {
        case text(String?)
        case violations([InputViolation])

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let text?): try container.encode(text)
            case .text(nil): try container.encodeNil()
            case .violations(let violations): try container.encode(violations)
            }
        }
    }

    struct Lines: Encodable, Sendable {
        var a: Int?
        var b: Int?

        private enum CodingKeys: String, CodingKey { case a, b }

        /// diff.py writes a line that is not known as null.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            let sides: [(key: CodingKeys, line: Int?)] = [(.a, a), (.b, b)]
            for (key, line) in sides {
                if let line { try container.encode(line, forKey: key) } else { try container.encodeNil(forKey: key) }
            }
        }
    }

    var step: String
    var index: UInt64
    var checkpoint = "settled"
    var pointer: String
    var kind = "value"
    var a: Value
    var b: Value
    var lines: Lines

    init(_ divergence: InputReplay.Divergence, line: Int?) {
        step = divergence.event
        index = divergence.seq
        switch divergence.kind {
        case .outcome:
            pointer = divergence.window == nil ? "/attach/phase" : "/focus/digest"
            a = .text(divergence.recorded)
            b = .text(divergence.replayed)
        case .checkpoint:
            pointer = "/focus/checkpoint"
            a = .text(divergence.recorded)
            b = .text(divergence.replayed)
        case .invariant:
            pointer = "/invariants"
            a = .violations([])
            b = .violations(divergence.violations)
        }
        lines = Lines(a: line, b: nil)
    }
}

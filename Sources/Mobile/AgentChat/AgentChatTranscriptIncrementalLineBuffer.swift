import Foundation

/// Frames live transcript growth without retaining an unbounded JSONL record.
///
/// Oversized records consume one sequence position and parsing resumes at the
/// next newline, preserving the absolute transcript line index for later rows.
struct AgentChatTranscriptIncrementalLineBuffer {
    private let maximumLineBytes: Int
    private(set) var pendingFragment = Data()
    private(set) var discardsUntilNextNewline = false

    init(maximumLineBytes: Int) {
        self.maximumLineBytes = max(1, maximumLineBytes)
    }

    /// Replaces the retained fragment after initial backfill or rotation.
    ///
    /// - Returns: Whether the supplied fragment exceeded the live-line bound
    ///   and is now being discarded through its next newline.
    @discardableResult
    mutating func reset(
        pendingFragment: Data = Data(),
        discardsUntilNextNewline: Bool = false
    ) -> Bool {
        self.pendingFragment = Data()
        if discardsUntilNextNewline || pendingFragment.count > maximumLineBytes {
            self.discardsUntilNextNewline = true
            return pendingFragment.count > maximumLineBytes
        }
        self.pendingFragment = pendingFragment
        self.discardsUntilNextNewline = false
        return false
    }

    mutating func append(_ data: Data) -> (
        lines: [String],
        discardedOversizedLine: Bool
    ) {
        guard !data.isEmpty else {
            return (lines: [], discardedOversizedLine: false)
        }
        var lines: [String] = []
        var discardedOversizedLine = false
        var cursor = data.startIndex

        while cursor < data.endIndex {
            if discardsUntilNextNewline {
                guard let newline = data[cursor...].firstIndex(of: 0x0A) else {
                    return (lines: lines, discardedOversizedLine: true)
                }
                lines.append("")
                discardedOversizedLine = true
                discardsUntilNextNewline = false
                cursor = data.index(after: newline)
                continue
            }

            guard let newline = data[cursor...].firstIndex(of: 0x0A) else {
                let suffix = data[cursor...]
                if pendingFragment.count + suffix.count > maximumLineBytes {
                    pendingFragment = Data()
                    discardsUntilNextNewline = true
                    discardedOversizedLine = true
                } else {
                    pendingFragment.append(contentsOf: suffix)
                }
                break
            }

            let fragment = data[cursor..<newline]
            if pendingFragment.count + fragment.count > maximumLineBytes {
                lines.append("")
                discardedOversizedLine = true
            } else if pendingFragment.isEmpty {
                lines.append(String(decoding: fragment, as: UTF8.self))
            } else {
                pendingFragment.append(contentsOf: fragment)
                lines.append(String(decoding: pendingFragment, as: UTF8.self))
            }
            pendingFragment = Data()
            cursor = data.index(after: newline)
        }

        return (
            lines: lines,
            discardedOversizedLine: discardedOversizedLine
        )
    }
}

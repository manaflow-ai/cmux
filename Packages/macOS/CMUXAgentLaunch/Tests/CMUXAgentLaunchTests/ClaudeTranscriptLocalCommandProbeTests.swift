import CMUXAgentLaunch
import Foundation
import Testing

/// Claude Code records `/effort` and `/model` in the session transcript as a user entry whose
/// content is the command's `<local-command-stdout>`, timestamped. The probe finds the newest
/// one after the time cmux last dismissed the user's choices, so a change that scrolled off
/// screen still leaves the pane alone.
@Suite("ClaudeTranscriptLocalCommandProbe")
struct ClaudeTranscriptLocalCommandProbeTests {
    private let dismissedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func stdoutLine(_ text: String, at date: Date) throws -> String {
        try jsonLine([
            "type": "user",
            "message": ["role": "user", "content": "<local-command-stdout>\(text)</local-command-stdout>"],
            "timestamp": timestamp(date),
            "sessionId": "s1",
        ])
    }

    private func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try #require(String(data: data, encoding: .utf8))
    }

    private func withTranscript(_ lines: [String], _ body: (String) throws -> Void) throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-command-\(UUID().uuidString).jsonl").path
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try body(path)
    }

    private func probe(_ path: String, maxTailBytes: Int = 512 * 1024) throws -> Date? {
        try ClaudeTranscriptLocalCommandProbe.lastEffortOrModelChange(
            transcriptPath: path,
            after: dismissedAt,
            maxTailBytes: maxTailBytes
        )
    }

    /// The milliseconds the transcript keeps, compared at that precision.
    private func sameInstant(_ lhs: Date?, _ rhs: Date) -> Bool {
        guard let lhs else { return false }
        return abs(lhs.timeIntervalSince(rhs)) < 0.001
    }

    @Test func findsAnEffortChangeAfterTheDismissal() throws {
        let changedAt = dismissedAt.addingTimeInterval(12.345)
        try withTranscript([
            try stdoutLine("Set effort level to max (this session only): Maximum capability", at: changedAt),
        ]) { path in
            let found = try probe(path)
            #expect(sameInstant(found, changedAt))
        }
    }

    @Test(arguments: [
        "Set model to `Opus 5.5` and saved as your default for new sessions",
        "Model set to opus",
        "Effort level set to high",
    ])
    func findsEveryChangeMarker(_ text: String) throws {
        let changedAt = dismissedAt.addingTimeInterval(1)
        try withTranscript([try stdoutLine(text, at: changedAt)]) { path in
            let found = try probe(path)
            #expect(sameInstant(found, changedAt))
        }
    }

    @Test func ignoresAChangeBeforeTheDismissal() throws {
        try withTranscript([
            try stdoutLine("Set effort level to low (this session only)", at: dismissedAt.addingTimeInterval(-30)),
            try stdoutLine("Set model to `Opus 5.5`", at: dismissedAt),
        ]) { path in
            let found = try probe(path)
            #expect(found == nil)
        }
    }

    @Test func returnsTheNewestChangeAfterTheDismissal() throws {
        let newest = dismissedAt.addingTimeInterval(90)
        try withTranscript([
            try stdoutLine("Set effort level to low", at: dismissedAt.addingTimeInterval(-5)),
            try stdoutLine("Set model to `Opus 5.5`", at: newest),
            try stdoutLine("Set effort level to high", at: dismissedAt.addingTimeInterval(20)),
        ]) { path in
            let found = try probe(path)
            #expect(sameInstant(found, newest))
        }
    }

    /// Escaping the `/effort` picker records the command but prints no change.
    @Test func ignoresACancelledEffortCommand() throws {
        let at = dismissedAt.addingTimeInterval(5)
        try withTranscript([
            try jsonLine([
                "type": "user",
                "message": ["role": "user", "content": "<command-name>/effort</command-name>\n<command-message>effort</command-message>\n<command-args></command-args>"],
                "timestamp": timestamp(at),
            ]),
            try stdoutLine("", at: at),
        ]) { path in
            let found = try probe(path)
            #expect(found == nil)
        }
    }

    @Test func ignoresUnrelatedCommandOutput() throws {
        let at = dismissedAt.addingTimeInterval(5)
        try withTranscript([
            try stdoutLine("Ultracode off. Effort stays xhigh.", at: at),
            try stdoutLine("Total cost: $0.42", at: at),
            // The marker outside a command's stdout is the conversation, not a change.
            try jsonLine([
                "type": "user",
                "message": ["role": "user", "content": "Set model to opus in the config file"],
                "timestamp": timestamp(at),
            ]),
            try jsonLine([
                "type": "assistant",
                "message": ["role": "assistant", "content": [["type": "text", "text": "<local-command-stdout>Set model to x</local-command-stdout>"]]],
                "timestamp": timestamp(at),
            ]),
            // A request blob quotes earlier stdout and carries no timestamp of its own.
            try jsonLine([
                "type": "api-request-blob",
                "message": ["role": "user", "content": [["type": "text", "text": "<local-command-stdout>Set effort level to max</local-command-stdout>"]]],
            ]),
        ]) { path in
            let found = try probe(path)
            #expect(found == nil)
        }
    }

    @Test func readsTextBlockContent() throws {
        let at = dismissedAt.addingTimeInterval(3)
        try withTranscript([
            try jsonLine([
                "type": "user",
                "message": ["role": "user", "content": [["type": "text", "text": "<local-command-stdout>Set effort level to high</local-command-stdout>"]]],
                "timestamp": timestamp(at),
            ]),
        ]) { path in
            let found = try probe(path)
            #expect(sameInstant(found, at))
        }
    }

    /// A tail that starts inside a line skips that line instead of misreading it.
    @Test func skipsATruncatedFirstLineInTheTail() throws {
        let changedAt = dismissedAt.addingTimeInterval(7)
        let earlier = try stdoutLine("Total cost: $0.01", at: dismissedAt.addingTimeInterval(-60))
        let change = try stdoutLine("Set effort level to max", at: changedAt)
        let unrelated = try stdoutLine("Total cost: $0.42", at: changedAt)
        try withTranscript([earlier, change, unrelated]) { path in
            // Starts a few bytes into the change line.
            let cutInside = change.utf8.count - 5 + 1 + unrelated.utf8.count + 1
            let insideLine = try probe(path, maxTailBytes: cutInside)
            #expect(insideLine == nil)
            // Starts exactly at the change line.
            let cutAtLineStart = change.utf8.count + 1 + unrelated.utf8.count + 1
            let atLineStart = try probe(path, maxTailBytes: cutAtLineStart)
            #expect(sameInstant(atLineStart, changedAt))
        }
    }

    @Test func aMissingTranscriptThrows() {
        #expect(throws: (any Error).self) {
            try ClaudeTranscriptLocalCommandProbe.lastEffortOrModelChange(
                transcriptPath: "/nonexistent/\(UUID().uuidString).jsonl",
                after: dismissedAt
            )
        }
    }
}

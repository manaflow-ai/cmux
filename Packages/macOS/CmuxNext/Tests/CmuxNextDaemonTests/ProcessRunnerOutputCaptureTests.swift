import Foundation
import Testing
@testable import CmuxNextDaemon

struct ProcessRunnerOutputCaptureTests {
    private static let reply = #"{"ok":true,"uploads":[{"path":"/session/original.bin"}]}"#

    @Test func manyHeartbeatsRetainTheFinalReplyWithoutCapturingTheirHistory() throws {
        let output = try TempOutput()
        let heartbeats = Data(String(repeating: "{\"progress\":\"upload\"}\n", count: 1_024).utf8)
        for _ in 0..<128 { try output.handle.write(contentsOf: heartbeats) }
        try output.handle.write(contentsOf: Data((Self.reply + "\n").utf8))
        let captured = output.contents(tailBytes: 4_096)
        #expect(captured.count == 4_096)
        let final = try #require(String(decoding: captured, as: UTF8.self).split(separator: "\n").last)
        #expect(String(final) == Self.reply)
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(final.utf8)) as? [String: Any])
        #expect(decoded["ok"] as? Bool == true)
    }

    @Test func sparseOutputLargerThanOneGiBStillAllocatesOnlyTheRequestedTail() throws {
        let output = try TempOutput()
        let offset: UInt64 = 1_073_741_825
        try output.handle.truncate(atOffset: offset)
        try output.handle.seek(toOffset: offset)
        try output.handle.write(contentsOf: Data(("\n" + Self.reply + "\n").utf8))
        let captured = output.contents(tailBytes: 512)
        #expect(captured.count == 512)
        #expect(String(decoding: captured, as: UTF8.self).hasSuffix(Self.reply + "\n"))
    }

    @Test func completeOutputRemainsTheDefault() throws {
        let output = try TempOutput()
        let original = Data(String(repeating: "original output\n", count: 4_096).utf8)
        try output.handle.write(contentsOf: original)
        #expect(output.contents() == original)
    }

    /// Stdin far past one pipe buffer reaches the child whole: it is fed after launch on the
    /// feed's queue, not written before the child exists (that write waited, on the main thread
    /// for a main-actor caller: the NIGHTLY's 391 s hang, 2026-11-09).
    @Test(.timeLimit(.minutes(1))) func stdinPastThePipeBufferReachesTheChildWhole() async throws {
        let input = Data(String(repeating: "0123456789abcdef", count: 64 * 1_024).utf8) // 1 MiB
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [],
                                                 environment: nil, stdin: input, timeout: .seconds(30),
                                                 clock: ContinuousClock())
        #expect(result.status == 0)
        #expect(result.stdout == input)
    }

    /// A child that exits without reading its stdin ends the run; the unread bytes never hold it.
    @Test(.timeLimit(.minutes(1))) func aChildThatNeverReadsStdinStillEnds() async throws {
        let input = Data(repeating: 0x61, count: 1_024 * 1_024)
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 3"],
                                                 environment: nil, stdin: input, timeout: .seconds(30),
                                                 clock: ContinuousClock())
        #expect(result.status == 3)
    }

    @Test(.timeLimit(.minutes(1))) func optInBoundsBothStreamsAndDefaultKeepsBothComplete() async throws {
        let script = """
        i=0
        while [ "$i" -lt 4096 ]; do
            printf '%s\\n' '{"progress":"upload"}'
            printf '%s\\n' 'upload diagnostic' >&2
            i=$((i + 1))
        done
        printf '%s\\n' '\(Self.reply)'
        printf '%s\\n' 'final diagnostic' >&2
        """
        for tailBytes: Int? in [nil, 1_024] {
            let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                                                     environment: nil, timeout: .seconds(10), outputTailBytes: tailBytes,
                                                     clock: ContinuousClock())
            #expect(result.status == 0)
            #expect(String(decoding: result.stdout, as: UTF8.self).hasSuffix(Self.reply + "\n"))
            #expect(String(decoding: result.stderr, as: UTF8.self).hasSuffix("final diagnostic\n"))
            if let tailBytes {
                #expect(result.stdout.count == tailBytes)
                #expect(result.stderr.count == tailBytes)
            } else {
                #expect(result.stdout.count > 64 * 1_024)
                #expect(result.stderr.count > 64 * 1_024)
                #expect(String(decoding: result.stdout, as: UTF8.self).hasPrefix("{\"progress\":\"upload\"}\n"))
                #expect(String(decoding: result.stderr, as: UTF8.self).hasPrefix("upload diagnostic\n"))
            }
        }
    }
}

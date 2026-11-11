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

    /// The gate test of fix/tip-reds-3-snapshot-scale-test (d4a3e02537e5), on the tree before #39998, where the stdin
    /// write ran on the caller's thread before the launch. NEVER MERGES. One addition for this tree only: the main
    /// thread stays in write(2) for ever here, so a thread of its own ends the process when the gate is still shut
    /// after 15 s, and prints why.
    @MainActor @Test(.timeLimit(.minutes(1))) func aMainActorCallerRunsWhileAChildWaitsToReadAMiBOfStdin() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "process-runner-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = directory.appending(path: "started").path, gate = directory.appending(path: "gate").path
        let input = Data(repeating: 0x61, count: 1_024 * 1_024)
        let opensTheGate = Task { @MainActor in
            while !FileManager.default.fileExists(atPath: started) {
                guard (try? await Task.sleep(for: .milliseconds(10))) != nil else { return false }
            }
            return FileManager.default.createFile(atPath: gate, contents: nil)
        }
        defer { opensTheGate.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            guard !FileManager.default.fileExists(atPath: gate) else { return }
            let childStarted = FileManager.default.fileExists(atPath: started)
            print("GATE-SHUT after 15 s: the main actor did not open the gate (child started: \(childStarted)); the process ends now")
            fflush(stdout)
            exit(87)
        }
        let script = #": > "$1"; while [ ! -e "$2" ]; do sleep 0.05; done; wc -c"#
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                                 arguments: ["-c", script, "sh", started, gate],
                                                 environment: nil, stdin: input, timeout: .seconds(30),
                                                 clock: ContinuousClock())
        let opened = await opensTheGate.value
        #expect(opened, "the main actor did not open the gate while the child waited for it")
        #expect(result.status == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "1048576")
    }

    @Test func completeOutputRemainsTheDefault() throws {
        let output = try TempOutput()
        let original = Data(String(repeating: "original output\n", count: 4_096).utf8)
        try output.handle.write(contentsOf: original)
        #expect(output.contents() == original)
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

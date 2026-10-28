import CmuxNextTerminal
import Foundation
import Testing

/// Input larger than the PTY's input queue waits in the local PTY's pending input (a checked Sendable since
/// p10-stability-052) and reaches the program whole and in order once it reads: the write source resumes
/// the flush each time the queue has room.
@Suite(.serialized, .timeLimit(.minutes(1))) struct LocalPTYPendingInputTests {
    @Test func inputLargerThanThePTYQueueArrivesWhole() async throws {
        // The program turns echo off, says it is ready, then counts the bytes it reads until VEOF. The kernel's
        // echo goes to a fixed-size output queue that drops bytes when full, so the test never counts echo.
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("pty-count-\(UUID().uuidString).sh")
        try "#!/bin/sh\nstty -echo\necho READY\nexec wc -c\n".write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let io = try LocalPTYTerminalIO(shell: script.path, workingDirectory: "/", installedTerminfo: false)
        defer { io.terminate() }
        // A stuck flush ends the program and the stream here, and fails the count below with its output.
        let deadline = Task {
            try await Task.sleep(for: .seconds(30))
            io.terminate()
        }
        defer { deadline.cancel() }

        var events = io.events.makeAsyncIterator()
        var output = ""
        while !output.contains("READY"), let event = await events.next() {
            if case .output(let data) = event { output += String(decoding: data, as: UTF8.self) }
        }
        let ready = try #require(output.range(of: "READY"), "the counter did not start: \(output.suffix(200))")

        // 2048 lines of 100 bytes: far more than the PTY's input queue, so the write waits in the pending input
        // and the write source resumes it as the program reads. VEOF at the start of a line ends the count.
        let lines = 2048
        let sent = lines * 100
        let payload = String(repeating: String(repeating: "a", count: 99) + "\n", count: lines)
        await io.write(Data((payload + "\u{04}").utf8))

        var report = String(output[ready.upperBound...])
        while let event = await events.next() {
            if case .output(let data) = event { report += String(decoding: data, as: UTF8.self) }
        }
        let counted = Int(report.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(counted == sent, "the program read \(counted.map(String.init) ?? "no count") of \(sent) bytes: \(report.suffix(200))")
    }
}

import CmuxNextCloud
import CmuxNextRemote
import Foundation
import Testing

/// #20776 item 1: a hung ssh (an unreachable host, a stuck remote command) must time out.
/// The deadline has to stop the process and return `DeadlineExceeded` promptly, not wait for
/// the process to exit on its own.
struct SSHProcessRunnerDeadlineTests {
    @Test func deadlineStopsAProcessThatOutlivesIt() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: DeadlineExceeded.self) {
            _ = try await SSHProcessRunner.run(["/bin/sleep", "30"], environment: [:],
                                               deadline: .milliseconds(300), label: "hung ssh")
        }
        let elapsed = clock.now - start
        #expect(elapsed < .seconds(5), "the deadline returned after \(elapsed), not near 300 ms")
    }

    @Test func closedStdinDoesNotSendSigpipeWhileWriting() async throws {
        let result = try await SSHProcessRunner.run(
            ["/bin/sh", "-c", "sleep 0.2; exec 0<&-; sleep 1"],
            input: .writer { descriptor in
                let bytes = [UInt8](repeating: 0x61, count: 1 << 20)
                bytes.withUnsafeBytes { buffer in
                    guard let base = buffer.baseAddress else { return }
                    _ = Darwin.write(descriptor, base, buffer.count)
                }
            },
            environment: [:], deadline: .seconds(3), label: "closed stdin")
        #expect(result.status == 0)
    }

    // Idle-bound runs: a slow transfer that keeps writing outlives the idle bound in total (1.2 s
    // against 500 ms); on base there was only a total deadline, so this run would have been cut off.
    @Test func idleRunKeepsAProcessThatKeepsWritingStderr() async throws {
        let result = try await SSHProcessRunner.run(
            ["/bin/sh", "-c", "i=0; while [ $i -lt 8 ]; do echo step >&2; i=$((i+1)); sleep 0.15; done"],
            environment: [:], idle: .milliseconds(500), label: "moving")
        #expect(result.status == 0)
    }

    @Test func idleRunKeepsAProcessWhoseWatchedFileGrows() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("idle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("partial")
        let result = try await SSHProcessRunner.run(
            ["/bin/sh", "-c", "i=0; while [ $i -lt 8 ]; do printf x >> \"$1\"; i=$((i+1)); sleep 0.15; done", "sh", file.path],
            environment: [:], idle: .milliseconds(500), watching: file, label: "quiet download")
        #expect(result.status == 0)
    }

    @Test func idleRunStopsASilentProcessAtTheIdleBound() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: DeadlineExceeded.self) {
            _ = try await SSHProcessRunner.run(["/bin/sleep", "30"], environment: [:],
                                               idle: .milliseconds(400), label: "silent")
        }
        #expect(clock.now - start < .seconds(5))
    }
}

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
}

import Foundation
import Testing
@testable import CmuxNextDaemon

/// `Process.processIdentifier` raises on a process that has not launched, and a caller cancelled
/// before `run` starts its child reaches `onCancel` first.
@Suite struct ProcessRunnerCancellationTests {
    private final class Sent: @unchecked Sendable {
        var pids: [pid_t] = []
    }

    @Test func killingAProcessThatNeverLaunchedSendsNothing() {
        let sent = Sent()
        let box = ProcessBox(Process(), signal: { pid, _ in sent.pids.append(pid) })
        box.kill()
        #expect(sent.pids.isEmpty)
    }

    @Test func aCallerThatIsAlreadyCancelledNeverStartsTheChild() async {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("process-runner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/touch"), arguments: [marker.path],
                                               environment: nil, timeout: .seconds(20), clock: ContinuousClock())
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}

import CmuxNextCompat
import Foundation
import Testing

/// `Process.runOnOwnThread` (p02-threads-040): the privileged server helper's spawn runs on a thread of its own at
/// the QoS it names, never on the caller's thread (Chromium's launcher thread,
/// content/browser/child_process_launcher_helper.cc), and the child gets the same QoS.
@Suite(.timeLimit(.minutes(1)))
struct ProcessOwnThreadTests {
    /// The process's owner, as the helper's FixChild: configured here, then touched only by the spawn thread and
    /// the termination handler.
    nonisolated final class Child: @unchecked Sendable {
        let process = Process()

        init(_ executable: String, _ arguments: [String]) {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
    }

    /// What the spawn thread saw when the launch failed.
    nonisolated struct SpawnThread: Sendable, Equatable {
        var isMain: Bool
        var name: String?
        var qos: QualityOfService
    }

    @MainActor
    @Test func aChildStartedFromTheMainActorReportsItsExitAndRunsAtTheQoS() async {
        let child = Child("/bin/sh", ["-c", "exit 3"])
        let status: Int32? = await withCheckedContinuation { continuation in
            child.process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            Process.runOnOwnThread(qos: .utility, name: "test.own-thread.exit", { child.process }) { _ in
                continuation.resume(returning: nil)
            }
        }
        #expect(status == 3)
        #expect(child.process.qualityOfService == .utility, "the child runs at the thread's QoS")
    }

    @MainActor
    @Test func aChildThatCannotStartFailsOnItsOwnNamedThreadAtItsQoS() async {
        let child = Child("/no/such/program", [])
        let seen: SpawnThread = await withCheckedContinuation { continuation in
            Process.runOnOwnThread(qos: .utility, name: "test.own-thread.missing", { child.process }) { _ in
                let thread = Thread.current
                continuation.resume(returning: SpawnThread(isMain: thread.isMainThread, name: thread.name,
                                                           qos: thread.qualityOfService))
            }
        }
        #expect(seen == SpawnThread(isMain: false, name: "test.own-thread.missing", qos: .utility))
    }
}

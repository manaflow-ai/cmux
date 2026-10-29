import CmuxNextCompat
import CmuxNextCompatCore
import Darwin
import Foundation
import Testing

/// `Process.runOnOwnThread`: the privileged server helper's spawn runs on a thread of its own at
/// the QoS it names, never on the caller's thread (Chromium's launcher thread,
/// content/browser/child_process_launcher_helper.cc), and the child itself runs at that QoS.
@Suite(.timeLimit(.minutes(1)))
struct ProcessOwnThreadTests {
    /// A test owner of a process configured up front, then touched only by the spawn thread and the termination
    /// handler. (The helper's FixChild stores no `Process`: it makes one inside `child`.)
    nonisolated final class Child: @unchecked Sendable {
        let process = Process()
        let output = Pipe()

        init(_ executable: String, _ arguments: [String]) {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
        }
    }

    /// The thread a callback of `runOnOwnThread` ran on.
    nonisolated struct SpawnThread: Sendable, Equatable {
        var isMain: Bool
        var name: String?
        /// `qos_class_self()`.
        var qos: UInt32

        /// The calling thread.
        static func current() -> SpawnThread {
            let thread = Thread.current
            return SpawnThread(isMain: thread.isMainThread, name: thread.name, qos: qos_class_self().rawValue)
        }
    }

    /// The first value one callback hands over.
    nonisolated final class Recorded<Value: Sendable>: Sendable {
        private let value = Mutex<Value?>(nil)

        func set(_ newValue: Value) {
            value.withLock { $0 = $0 ?? newValue }
        }

        var first: Value? {
            value.withLock { $0 }
        }
    }

    /// How a run of `child` ended: its exit status and what it printed.
    nonisolated struct Ended: Sendable {
        var status: Int32
        var output: String
    }

    /// Starts `child` at `qos`, records the spawn thread in `spawn`, and returns its end (nil when it did not start).
    static func run(_ child: Child, qos: QualityOfService, name: String, spawn: Recorded<SpawnThread>) async -> Ended? {
        let output = child.output
        return await withCheckedContinuation { continuation in
            child.process.terminationHandler = { ended in
                // The children here print a few bytes, far below the pipe buffer.
                let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
                continuation.resume(returning: Ended(status: ended.terminationStatus, output: String(decoding: data, as: UTF8.self)))
            }
            Process.runOnOwnThread(qos: qos, name: name, { spawn.set(.current()); return child.process },
                                   launched: { _ in spawn.set(.current()) },
                                   failed: { _ in continuation.resume(returning: nil) })
        }
    }

    @MainActor
    @Test func aChildStartedFromTheMainActorSpawnsOnItsOwnNamedThreadAtTheQoS() async {
        let spawn = Recorded<SpawnThread>()
        let ended = await Self.run(Child("/bin/sh", ["-c", "exit 3"]), qos: .utility, name: "test.own-thread.exit", spawn: spawn)
        #expect(ended?.status == 3)
        #expect(spawn.first == SpawnThread(isMain: false, name: "test.own-thread.exit", qos: QOS_CLASS_UTILITY.rawValue))
    }

    /// The child reports its own scheduling priority (`ps -o pri` of its shell): a utility child runs below a
    /// userInitiated one, so the QoS reached the child, not only the `Process` property.
    @Test func theChildItselfRunsAtTheQoS() async throws {
        let script = "/bin/ps -o pri= -p $$"
        let utility = await Self.run(Child("/bin/sh", ["-c", script]), qos: .utility, name: "test.own-thread.utility",
                                     spawn: Recorded())
        let initiated = await Self.run(Child("/bin/sh", ["-c", script]), qos: .userInitiated,
                                       name: "test.own-thread.initiated", spawn: Recorded())
        let low = try #require(utility.flatMap { Int($0.output.trimmingCharacters(in: .whitespacesAndNewlines)) })
        let high = try #require(initiated.flatMap { Int($0.output.trimmingCharacters(in: .whitespacesAndNewlines)) })
        #expect(low < high, "a utility child runs at priority \(low), a userInitiated one at \(high)")
    }

    @MainActor
    @Test func aChildThatCannotStartFailsOnItsOwnNamedThreadAtItsQoS() async {
        let child = Child("/no/such/program", [])
        let seen: SpawnThread = await withCheckedContinuation { continuation in
            Process.runOnOwnThread(qos: .utility, name: "test.own-thread.missing", { child.process },
                                   launched: { _ in Issue.record("a missing program started") },
                                   failed: { _ in continuation.resume(returning: .current()) })
        }
        #expect(seen == SpawnThread(isMain: false, name: "test.own-thread.missing", qos: QOS_CLASS_UTILITY.rawValue))
    }
}

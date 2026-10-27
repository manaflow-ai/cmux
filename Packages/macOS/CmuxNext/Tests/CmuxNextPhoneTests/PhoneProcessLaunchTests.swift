import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing
@testable import CmuxNextPhone

/// Task p02-threads-039 (plans/cmux-next/chrome-parity/p02-threads.md, INV-3): a phone tool spawns on its
/// `ProcessLauncher` queue, never on the caller's thread, at the launcher's child priority, and its stdin is
/// written without holding the caller.
@Suite(.timeLimit(.minutes(1))) struct PhoneProcessLaunchTests {
    /// A start that spawned by itself on the caller's actor records no spawn and fails here.
    @MainActor @Test func aToolStartedFromTheMainActorSpawnsOffItAtItsChildPriority() async throws {
        let probe = SpawnProbe(childPriority: .bestEffort)
        let result = try await PhoneProcessRunner(launcher: nil, processLauncher: probe.launcher)
            .run(["/bin/sh", "-c", "/bin/cat"], stdin: Data("hi".utf8), deadline: .seconds(20))
        #expect(await probe.recorded() == [SpawnProbe.Spawn(onMain: false, qualityOfService: WorkPriority.bestEffort.processQoS)])
        #expect(result.status == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "hi")
    }

    /// stdin past the pipe's 64 KiB buffer, to a child that does not read it yet: the launch returns while
    /// the child still runs. A write on the caller's thread would hold it (the main thread here) until the
    /// child read or exited.
    @MainActor @Test func aLargeStdinNeverHoldsTheCaller() async throws {
        let payload = Data(repeating: 0x61, count: 1 << 20)
        let command = try await PhoneProcess.launch(launcher: nil, arguments: ["/bin/sh", "-c", "exec /bin/sleep 30"], stdin: payload,
                                                    stdoutFile: nil, captureStdout: false,
                                                    spawner: ProcessLauncher(label: "com.cmuxterm.next.test.phone", priority: .userVisible))
        #expect(command.isRunning, "the launch waited for the child to take its stdin")
        await command.interrupt()
        #expect(await command.waitForExit(deadline: .seconds(20)) != 0)
    }

    /// A large stdin the child reads arrives whole.
    @Test func aLargeStdinReachesTheChildWhole() async throws {
        let payload = Data((0..<(256 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
        let result = try await PhoneProcessRunner(launcher: nil).run(["/bin/cat"], stdin: payload, deadline: .seconds(20))
        #expect(result.status == 0)
        #expect(result.stdout == payload)
    }

    @Test func aMissingToolThrowsItsLaunchError() async {
        await #expect(throws: (any Error).self) {
            _ = try await PhoneProcessRunner(launcher: nil).run(["/no/such/adb"], stdin: nil, deadline: .seconds(5))
        }
    }
}

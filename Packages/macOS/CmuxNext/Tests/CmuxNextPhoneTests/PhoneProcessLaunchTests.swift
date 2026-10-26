import Foundation
import Testing
@testable import CmuxNextPhone

/// Task p02-threads-039 (plans/cmux-next/chrome-parity/p02-threads.md, INV-3): a phone tool starts on a
/// `ProcessLauncher` queue, never on the caller's thread, and never at the main thread's QoS.
@Suite(.timeLimit(.minutes(1))) struct PhoneProcessLaunchTests {
    @MainActor @Test func aToolStartedFromTheMainActorRunsBelowUserInteractive() async throws {
        let command = try await PhoneProcess.launch(launcher: nil, arguments: ["/bin/sh", "-c", "/bin/cat"], stdin: Data("hi".utf8),
                                                    stdoutFile: nil, captureStdout: true)
        #expect(command.qualityOfService != .userInteractive)
        #expect(await command.waitForExit(deadline: .seconds(20)) == 0)
        #expect(String(decoding: command.stdout, as: UTF8.self) == "hi")
    }

    @Test func aMissingToolThrowsItsLaunchError() async {
        await #expect(throws: (any Error).self) {
            _ = try await PhoneProcessRunner(launcher: nil).run(["/no/such/adb"], stdin: nil, deadline: .seconds(5))
        }
    }
}

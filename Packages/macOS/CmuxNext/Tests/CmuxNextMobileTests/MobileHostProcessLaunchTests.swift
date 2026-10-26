import CmuxNextMobile
import Foundation
import Testing

/// Task p02-threads-039 (plans/cmux-next/chrome-parity/p02-threads.md, INV-3): hostd starts on a
/// `ProcessLauncher` queue, never on the caller's thread, and never at the main thread's QoS. `/bin/cat`
/// stands in for hostd: it echoes each control line and exits when stdin closes, as hostd does.
@Suite(.timeLimit(.minutes(1))) struct MobileHostProcessLaunchTests {
    func launch(_ executable: String) throws -> MobileHostLaunch {
        MobileHostLaunch(executable: URL(fileURLWithPath: executable), baseURL: try #require(URL(string: "https://mobile.invalid")),
                         teamID: "team", userID: "user", deviceID: "device", deviceName: "Mac", daemonSocket: "/nonexistent.sock",
                         stateDirectory: FileManager.default.temporaryDirectory, fileRoots: [], stackProjectID: "project")
    }

    @MainActor @Test func hostdStartedFromTheMainActorEchoesAndEndsWithItsStdin() async throws {
        let child = MobileHostProcess()
        try await child.start(launch("/bin/cat"), environment: [:], log: nil)
        #expect(child.qualityOfService != nil)
        #expect(child.qualityOfService != .userInteractive)
        #expect((child.pid ?? 0) > 0)
        var lines = child.lines.makeAsyncIterator()
        #expect(child.send(Data("hello\n".utf8)))
        let echoed = await lines.next()
        #expect(echoed == "hello")
        child.stop()
        _ = await child.waitForExit()
        #expect(!child.send(Data("late\n".utf8)), "a line reached a gone hostd")
    }

    @Test func aMissingHostdThrowsFromStart() async throws {
        let child = MobileHostProcess()
        let missing = try launch("/no/such/cmux-mobile-host")
        await #expect(throws: (any Error).self) { try await child.start(missing, environment: [:], log: nil) }
    }
}

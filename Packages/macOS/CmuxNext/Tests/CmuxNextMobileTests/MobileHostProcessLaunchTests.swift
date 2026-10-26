import CmuxNextMobile
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// Task p02-threads-039 (plans/cmux-next/chrome-parity/p02-threads.md, INV-3): hostd spawns on its injected
/// `ProcessLauncher` queue, never on the caller's thread, at the launcher's child priority. `/bin/cat` stands
/// in for hostd: it echoes each control line and exits when stdin closes, as hostd does.
@Suite(.timeLimit(.minutes(1))) struct MobileHostProcessLaunchTests {
    func launch(_ executable: String) throws -> MobileHostLaunch {
        MobileHostLaunch(executable: URL(fileURLWithPath: executable), baseURL: try #require(URL(string: "https://mobile.invalid")),
                         teamID: "team", userID: "user", deviceID: "device", deviceName: "Mac", daemonSocket: "/nonexistent.sock",
                         stateDirectory: FileManager.default.temporaryDirectory, fileRoots: [], stackProjectID: "project")
    }

    /// A start that spawned by itself on the caller's actor records no spawn and fails here.
    @MainActor @Test func hostdStartedFromTheMainActorSpawnsOffItEchoesAndEndsWithItsStdin() async throws {
        let probe = SpawnProbe(childPriority: .userVisible)
        let child = MobileHostProcess(launcher: probe.launcher)
        try await child.start(launch("/bin/cat"), environment: [:], log: nil)
        #expect(await probe.recorded() == [SpawnProbe.Spawn(onMain: false, qualityOfService: WorkPriority.userVisible.processQoS)])
        #expect((child.pid ?? 0) > 0)
        var lines = child.lines.makeAsyncIterator()
        #expect(child.send(Data("hello\n".utf8)))
        let echoed = await lines.next()
        #expect(echoed == "hello")
        child.stop()
        _ = await child.waitForExit()
        #expect(!child.send(Data("late\n".utf8)), "a line reached a gone hostd")
    }

    /// A stop() before the launch finished found no child to end: the launch ends hostd itself, so it
    /// never runs on with nobody to stop it (and stop() never terminates an unlaunched Process).
    @Test func aStopBeforeTheLaunchFinishedEndsHostd() async throws {
        let child = MobileHostProcess()
        child.stop()
        try await child.start(launch("/bin/cat"), environment: [:], log: nil)
        _ = await child.waitForExit()
        #expect(!child.send(Data("late\n".utf8)), "a line reached a stopped hostd")
    }

    @Test func aMissingHostdThrowsFromStart() async throws {
        let child = MobileHostProcess()
        let missing = try launch("/no/such/cmux-mobile-host")
        await #expect(throws: (any Error).self) { try await child.start(missing, environment: [:], log: nil) }
        #expect(child.pid == nil, "a hostd that never started has a pid")
    }
}

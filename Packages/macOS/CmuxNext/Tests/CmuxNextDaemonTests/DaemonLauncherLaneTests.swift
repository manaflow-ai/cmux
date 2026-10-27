import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextDaemon

/// p02-threads-053 (plans/cmux-next/chrome-parity/p02-threads.md, maybe-main-blocking): `DaemonLauncher.ensure`
/// makes its state directory on the files lane, never on the caller's thread (the launch's first connect and every
/// reconnect await it). The binary is `/usr/bin/false`, so `ensure` fails after the directory step, quickly.
@Suite(.timeLimit(.minutes(1))) struct DaemonLauncherLaneTests {
    @Test func ensureMakesTheStateDirectoryOnTheFilesLane() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "launcher-lane-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appending(path: "state", directoryHint: .isDirectory)
        let (runs, ran) = AsyncStream.makeStream(of: BlockingLane.self)
        let work = BackgroundWork(label: "test.launcher-lane", onRan: { lane, _, _, _ in ran.yield(lane) })
        let launcher = DaemonLauncher(work: work,
                                      configuration: .init(binary: URL(fileURLWithPath: "/usr/bin/false"), session: "lane-test", stateDirectory: state),
                                      environment: { [:] })

        _ = try? await launcher.ensure()

        var first = runs.makeAsyncIterator()
        #expect(await first.next() == .files, "the state directory was not made on the files lane")
        let attributes = try FileManager.default.attributesOfItem(atPath: state.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }
}

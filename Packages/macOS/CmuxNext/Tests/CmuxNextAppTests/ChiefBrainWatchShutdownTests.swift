import Darwin
import Foundation
@testable import CmuxNextHomeEngine
import Testing

/// cx-ro17i: `cmux chief shutdown` stopped the brain and the app started a
/// new one 18 ms later (cosmic-gray 2026-10-14). While the shutdown's
/// marker (`state/shutdown`) is there, a brain that exits stays stopped; a
/// brain that exits without it is started again.
@MainActor @Suite(.serialized) struct ChiefBrainWatchShutdownTests {
    @Test func aBrainStoppedByChiefShutdownIsNotStartedAgain() async throws {
        #expect(try await restartsAfterExit(shutdown: true) == 0)
    }

    @Test func aBrainThatDiesIsStartedAgain() async throws {
        #expect(try await restartsAfterExit(shutdown: false) == 1)
    }

    /// Watches a stand-in brain, ends it and counts the watch's restarts.
    private func restartsAfterExit(shutdown: Bool) async throws -> Int {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chief-watch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = ChiefHome(root: root, isolated: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("state"), withIntermediateDirectories: true)
        if shutdown { try Data().write(to: root.appendingPathComponent("state/shutdown")) }
        let brain = Process()
        brain.executableURL = URL(fileURLWithPath: "/bin/sleep")
        brain.arguments = ["30"]
        try brain.run()
        var restarts = 0
        let watch = ChiefBrainWatch(home: home) {
            restarts += 1
            return nil
        }
        watch.watch(brain.processIdentifier)
        brain.terminate()
        brain.waitUntilExit()
        let deadline = ContinuousClock.now + .seconds(2)
        while restarts == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        watch.stop()
        return restarts
    }
}

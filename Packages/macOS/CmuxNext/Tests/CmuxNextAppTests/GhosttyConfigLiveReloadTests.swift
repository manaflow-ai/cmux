@testable import CmuxNextApp
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// p06-scheduler-301: a Ghostty config save reloads once, after the 75 ms debounce, which is a `MainDeadline` on the
/// app's deadline scheduler (`MainDeadlineRig`: its uptime moves only when the rig fires a wake), and the file event's
/// hop to main is a posted task; after `stop()` a save reloads nothing. The launch's watch is an afterStartup post
/// (Q13, p08-startup-086): nothing is armed before startup completes, and a save made in the launch reloads once when it arms.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct GhosttyConfigLiveReloadTests {
    final class Reloads {
        var count = 0
    }

    @Test func aSaveReloadsOnceAfterTheDebounceOnTheAppsDeadlineScheduler() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "cnc-ghostty-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "config")
        try Data("font-size = 12\n".utf8).write(to: file)
        let rig = MainDeadlineRig()
        let reloads = Reloads()
        let live = GhosttyConfigLiveReload(deadlines: rig.deadlines, files: { [file.path] }, reload: { reloads.count += 1 },
                                           onConfigChange: { _ in })
        live.start()
        // The watch arms off main: save until one event has reached main and its debounce fired.
        let end = Date(timeIntervalSinceNow: 5)
        var saves = 0
        while reloads.count == 0, Date() < end {
            saves += 1
            try Data("font-size = \(12 + saves)\n".utf8).write(to: file)
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            rig.fireAndRun()
        }
        #expect(reloads.count == 1, "a save reloads the config once")
        #expect(rig.elapsed >= 0.075, "the reload waited the 75 ms debounce on the app's deadline scheduler")

        live.stop()
        try Data("font-size = 99\n".utf8).write(to: file)
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.2))
        rig.fireAndRun()
        rig.fireAndRun()
        #expect(reloads.count == 1, "a stopped watch reloads nothing")
    }

    @Test func theLaunchWatchArmsOnlyAfterStartupCompletes() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "config")
        try Data("font-size = 12\n".utf8).write(to: file)
        let rig = MainDeadlineRig()
        let s = StartupTestScheduler()
        let arms = Reloads()
        let live = GhosttyConfigLiveReload(deadlines: rig.deadlines, files: { arms.count += 1; return [file.path] }, reload: {},
                                           onConfigChange: { _ in })
        defer { live.stop() }
        live.startAfterStartup(on: s.startup)
        s.hand.drain()
        for _ in 0..<3 { s.fire() }
        #expect(arms.count == 0, "the config watch armed before startup completed")
        s.complete()
        s.hand.drain()
        for _ in 0..<3 { s.fire() }
        #expect(arms.count == 1, "the config watch armed once after startup completed")
        #expect(s.startup.log.records.map(\.name.description) == ["GhosttyConfigLiveReload.start"])
    }

    @Test func aSaveDuringTheLaunchReloadsOnceWhenTheWatchArms() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "config")
        try Data("font-size = 12\n".utf8).write(to: file)
        let rig = MainDeadlineRig()
        let s = StartupTestScheduler()
        let reloads = Reloads()
        let live = GhosttyConfigLiveReload(deadlines: rig.deadlines, files: { [file.path] }, reload: { reloads.count += 1 },
                                           onConfigChange: { _ in })
        defer { live.stop() }
        live.startAfterStartup(on: s.startup)
        try Data("font-size = 13\n".utf8).write(to: file)  // saved in the launch, before the watch exists
        s.complete()
        s.hand.drain()
        for _ in 0..<3 { s.fire() }
        // The arm's change-time check runs off main: wait for its event to reach main and the debounce to fire.
        let end = Date(timeIntervalSinceNow: 5)
        while reloads.count == 0, Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            rig.fireAndRun()
        }
        #expect(reloads.count == 1, "a save made before the launch's watch armed was lost")
    }

    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "cnc-ghostty-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

@testable import CmuxNextApp
@testable import CmuxNextSettings
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// A Ghostty config save reloads once, after the 75 ms debounce, which is a `MainDeadline` on the
/// app's deadline scheduler (`MainDeadlineRig`: its uptime moves only when the rig fires a wake), and the file event's
/// hop to main is a posted task; after `stop()` a save reloads nothing. The launch's watch is an afterStartup post
/// (Q13): nothing is armed before startup completes, and a save made in the launch reloads once when it arms.
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
        let reads = Reloads()
        let live = GhosttyConfigLiveReload(deadlines: rig.deadlines, files: { reads.count += 1; return [file.path] }, reload: {},
                                           onConfigChange: { _ in })
        defer { live.stop() }
        live.startAfterStartup(on: s.startup)
        s.hand.drain()
        for _ in 0..<3 { s.fire() }
        #expect(reads.count == 1, "the launch call reads the file list once, to mark each file, and arms nothing")
        s.complete()
        s.hand.drain()
        for _ in 0..<3 { s.fire() }
        #expect(reads.count == 2, "the config watch armed once after startup completed")
        #expect(s.startup.log.records.map(\.name.description) == ["GhosttyConfigLiveReload.start"])
    }

    @Test func aSaveDuringTheLaunchReloadsOnceWhenTheWatchArms() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "config")
        try Data("font-size = 12\n".utf8).write(to: file)
        let rig = MainDeadlineRig()
        let s = StartupTestScheduler()
        let reloads = Reloads()
        let queue = DispatchQueue(label: "test.ghostty-live.launch-save", qos: .utility)
        let live = Self.live(rig, files: [file.path], queue: queue) { reloads.count += 1 }
        defer { live.stop() }
        live.startAfterStartup(on: s.startup)
        await Self.fence(queue)  // the launch's mark is recorded
        try Data("font-size = 13\n".utf8).write(to: file, options: .atomic)  // saved in the launch, before the watch exists
        s.complete()
        s.hand.drain()
        for _ in 0..<3 { s.fire() }
        await Self.fence(queue)  // the arm compared the file with the mark
        Self.deliver(rig)
        #expect(reloads.count == 1, "a save made before the launch's watch armed was lost")
    }

    /// The watched folders hold other files (~/Library/Application Support, ~/.config, the build's own state folder): one
    /// added, replaced or removed during the launch is not a config save, so the late arm reloads nothing; a real save
    /// after it still reloads once.
    @Test func anotherFileOfTheFolderDuringTheLaunchReloadsNothing() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "config")
        try Data("font-size = 12\n".utf8).write(to: file)
        try Data("{}".utf8).write(to: folder.appending(path: "old-state.json"))
        let rig = MainDeadlineRig()
        let s = StartupTestScheduler()
        let reloads = Reloads()
        let queue = DispatchQueue(label: "test.ghostty-live.launch-sibling", qos: .utility)
        let live = Self.live(rig, files: [file.path, folder.appending(path: "config.ghostty").path], queue: queue) { reloads.count += 1 }
        defer { live.stop() }
        live.startAfterStartup(on: s.startup)
        await Self.fence(queue)
        try Data("{}".utf8).write(to: folder.appending(path: "sidebar.json"))
        try Data("{}".utf8).write(to: folder.appending(path: "state.json"), options: .atomic)
        try FileManager.default.removeItem(at: folder.appending(path: "old-state.json"))
        s.complete()
        s.hand.drain()
        for _ in 0..<3 { s.fire() }
        await Self.fence(queue)
        Self.deliver(rig)
        #expect(reloads.count == 0, "the late arm reloaded the config for a file that is not part of it")

        try Data("font-size = 14\n".utf8).write(to: file, options: .atomic)
        let end = Date(timeIntervalSinceNow: 5)
        while reloads.count == 0, Date() < end { Self.deliver(rig) }
        #expect(reloads.count == 1, "the armed watch heard a real save")
    }

    /// A reload watch whose file watchers run on `queue`, which the test fences.
    private static func live(_ rig: MainDeadlineRig, files: [String], queue: DispatchQueue,
                             reload: @escaping @MainActor () -> Void) -> GhosttyConfigLiveReload {
        GhosttyConfigLiveReload(deadlines: rig.deadlines, files: { files }, reload: reload, onConfigChange: { _ in },
                                makeWatcher: { ConfigFileWatcher(url: $0, queue: queue, onChange: $1) })
    }

    /// Runs after everything already queued on `queue`.
    private static func fence(_ queue: DispatchQueue) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
    }

    /// Runs the main hops of the watchers' reports, then fires the reload debounce.
    private static func deliver(_ rig: MainDeadlineRig) {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        rig.fireAndRun()
        rig.fireAndRun()
    }

    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "cnc-ghostty-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

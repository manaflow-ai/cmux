@testable import CmuxNextApp
import CmuxNextTerminal
import CmuxNextWakeups
import Foundation
import Testing

/// The Ghostty config watch at launch (p08-startup-026): it starts after the first frame, ends the launch's
/// in-memory config files before it reads which files to watch, and reloads once when a file the launch read
/// changed before the watch was armed.
@MainActor @Suite(.timeLimit(.minutes(1))) struct GhosttyConfigLiveReloadLaunchTests {
    /// Launch files of one top-level file, read from a fake file system.
    static func launchFiles() throws -> GhosttyConfigFiles {
        try #require(GhosttyConfigFiles.read(.init(override: "/t/config", home: "/h"), reader: .init(
            entry: { _ in .file(Data("font-size = 12\n".utf8)) }, resolve: { .resolved($0) })))
    }

    static func liveReload(_ calls: LiveReloadCalls, launch: GhosttyRuntime.LaunchConfig?, changed: Bool) -> GhosttyConfigLiveReload {
        GhosttyConfigLiveReload(files: { calls.names.append("files"); return [] },
                                reload: { calls.names.append("reload") },
                                endLaunch: { calls.names.append("endLaunch"); return launch },
                                checkLaunchFiles: { _, answer in
                                    calls.names.append("check")
                                    calls.answers.append { answer(changed) }
                                },
                                notifications: NotificationCenter())
    }

    @Test func aLaunchFileChangedBeforeTheWatchReloadsOnceAfterTheLaunchEnded() throws {
        let calls = LiveReloadCalls()
        let live = Self.liveReload(calls, launch: .memory(try Self.launchFiles()), changed: true)
        live.start()
        #expect(calls.names == ["endLaunch", "files", "check"],
                "the launch ends before the watch lists its files, and the check starts once the watch is armed")
        calls.answer()
        #expect(calls.names == ["endLaunch", "files", "check", "reload"], "the answer comes on a later turn")
        live.stop()
    }

    @Test func unchangedLaunchFilesNeedNoReload() throws {
        let calls = LiveReloadCalls()
        let live = Self.liveReload(calls, launch: .memory(try Self.launchFiles()), changed: false)
        live.start()
        calls.answer()
        #expect(calls.names == ["endLaunch", "files", "check"])
        live.stop()
    }

    @Test func anAnswerAfterStopReloadsNothing() throws {
        let calls = LiveReloadCalls()
        let live = Self.liveReload(calls, launch: .memory(try Self.launchFiles()), changed: true)
        live.start()
        live.stop()
        calls.answer()
        #expect(calls.names == ["endLaunch", "files", "check"])
    }

    @Test func aDiskLaunchHasNoStampsSoItReloadsOnce() {
        let calls = LiveReloadCalls()
        let live = Self.liveReload(calls, launch: .disk, changed: false)
        live.start()
        live.start()
        #expect(calls.answers.isEmpty, "nothing to compare")
        #expect(calls.names == ["endLaunch", "files", "reload"], "one reload, and a second start does nothing")
        live.stop()
    }

    @Test func theWatchWaitsForTheFirstFrame() throws {
        let f = LaunchOrderFixture()
        let calls = LiveReloadCalls()
        let live = Self.liveReload(calls, launch: nil, changed: false)
        live.start(after: f.order.startup)
        f.hand.drain()
        for _ in 0..<3 { f.fire() }
        #expect(calls.names.isEmpty, "until the first frame the launch's files serve every load and nothing is watched")
        let record = try #require(f.order.startup.log.records.first { $0.name.description == "Ghostty.configLiveReload" })
        #expect(record.priority == .afterFirstFrame)
        #expect(record.destination == .main)
        f.order.startup.firstFrameCommitted()
        for _ in 0..<3 { f.fire() }
        #expect(calls.names == ["endLaunch", "files"])
        live.stop()
    }
}

/// What the live reload called, in order.
@MainActor
final class LiveReloadCalls {
    var names: [String] = []
    /// The launch checks' answers, held until ``answer()`` (the files lane's reply on a later main turn).
    var answers: [@MainActor () -> Void] = []

    func answer() {
        let pending = answers
        answers = []
        pending.forEach { $0() }
    }
}

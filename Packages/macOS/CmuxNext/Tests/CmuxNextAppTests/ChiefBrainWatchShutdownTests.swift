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

    /// Home's default Chief is this Mac's while its brain runs, so the watch says when the host
    /// it watches changes: a brain that Home's opening started would otherwise leave Auto on the
    /// Hosted Chief for the whole launch (review of #23984).
    @Test func theWatchSaysWhichHostItWatchesOncePerChange() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chief-watch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = ChiefHome(root: root, isolated: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("state"), withIntermediateDirectories: true)
        // The shutdown marker keeps the exit from starting another host, so only the change shows.
        try Data().write(to: root.appendingPathComponent("state/shutdown"))
        let brain = Process()
        brain.executableURL = URL(fileURLWithPath: "/bin/sleep")
        brain.arguments = ["30"]
        try brain.run()
        var seen: [pid_t?] = []
        let watch = ChiefBrainWatch(home: home, restart: { nil }, watching: { seen.append($0) })
        watch.watch(brain.processIdentifier)
        #expect(seen == [brain.processIdentifier], "the started host")
        watch.watch(brain.processIdentifier)
        #expect(seen == [brain.processIdentifier], "the same host again says nothing")
        brain.terminate()
        brain.waitUntilExit()
        let deadline = ContinuousClock.now + .seconds(2)
        while seen.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        // Asserted before `stop()`, which reports nil itself: the nil here is the exit's.
        #expect(seen == [brain.processIdentifier, nil], "the host died: no host runs")
        watch.stop()
    }

    /// A launch whose pid the shell did not print watches nothing until the host takes the home's
    /// lock a moment later. The watch waits on the state folder for that, so Home's Auto engine
    /// hears the host without another ask (review of #23984).
    @Test func aHostThatTakesTheLockAfterTheLaunchIsStillWatched() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chief-watch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = ChiefHome(root: root, isolated: true)
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let brain = Process()
        brain.executableURL = URL(fileURLWithPath: "/bin/sleep")
        brain.arguments = ["30"]
        try brain.run()
        defer { brain.terminate() }
        var seen: [pid_t?] = []
        // The stand-in brain is not a real optchat-chief, so the lock's pid is read as a host here.
        let watch = ChiefBrainWatch(home: home, restart: { nil }, watching: { seen.append($0) },
                                    isChiefHost: { $0 == brain.processIdentifier })
        // The launch gave no pid and no host holds the lock yet: nothing watched, nothing reported.
        watch.watch(nil)
        #expect(seen.isEmpty, "no host yet: nothing to report")

        // The host takes the lock, which is what it writes its pid into.
        try Data("\(brain.processIdentifier)\n".utf8).write(to: state.appendingPathComponent("host.lock"))
        let deadline = ContinuousClock.now + .seconds(5)
        while seen.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(seen == [brain.processIdentifier], "the host that took the lock is watched")
        watch.stop()
    }

    /// The host rewrites an existing lock in place (`lock.rs` opens it with `create(true)`,
    /// `set_len(0)`s it and writes; it never removes the file), so on every home but a brand new
    /// one the lock's change raises an event on the *file*, never on the folder that holds it.
    @Test func aHostThatRewritesAnExistingLockIsStillWatched() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chief-watch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = ChiefHome(root: root, isolated: true)
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let lock = state.appendingPathComponent("host.lock")
        let brain = Process()
        brain.executableURL = URL(fileURLWithPath: "/bin/sleep")
        brain.arguments = ["30"]
        try brain.run()
        defer { brain.terminate() }
        // A lock an earlier host left, naming a pid that is not a host now.
        try Data("999999\n".utf8).write(to: lock)
        var seen: [pid_t?] = []
        let watch = ChiefBrainWatch(home: home, restart: { nil }, watching: { seen.append($0) },
                                    isChiefHost: { $0 == brain.processIdentifier })
        watch.watch(nil)
        #expect(seen.isEmpty, "the stale lock names no host: nothing to report")

        // The host takes the lock: the file is rewritten where it already was, so the folder
        // it sits in never changes.
        try Data("\(brain.processIdentifier)\n".utf8).write(to: lock)
        let deadline = ContinuousClock.now + .seconds(5)
        while seen.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(seen == [brain.processIdentifier], "the host that rewrote the lock is watched")
        watch.stop()
    }

    /// A fresh home has no lock file to watch, so the watch arms on the folder. The host creates
    /// the lock there and writes its pid a moment later: the folder's event must add the file's
    /// source without dropping the folder's, or that later write reaches no one. Once a host is
    /// watched, a further folder change must not arm anything again.
    @Test func aLockCreatedEmptyAndWrittenLaterIsStillWatched() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chief-watch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = ChiefHome(root: root, isolated: true)
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let lock = state.appendingPathComponent("host.lock")
        let brain = Process()
        brain.executableURL = URL(fileURLWithPath: "/bin/sleep")
        brain.arguments = ["30"]
        try brain.run()
        defer { brain.terminate() }
        var seen: [pid_t?] = []
        let watch = ChiefBrainWatch(home: home, restart: { nil }, watching: { seen.append($0) },
                                    isChiefHost: { $0 == brain.processIdentifier })
        // No lock file at all: only the folder can be watched.
        watch.watch(nil)
        #expect(seen.isEmpty, "no lock yet: nothing to report")

        // The host creates the lock, empty, and writes its pid only afterwards.
        try Data().write(to: lock)
        try await Task.sleep(for: .milliseconds(200))
        #expect(seen.isEmpty, "an empty lock names no host")
        try Data("\(brain.processIdentifier)\n".utf8).write(to: lock)
        let deadline = ContinuousClock.now + .seconds(5)
        while seen.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(seen == [brain.processIdentifier], "the pid written after the lock's creation is watched")

        // A folder change now, with a host watched, reports nothing more.
        try Data("x".utf8).write(to: state.appendingPathComponent("other"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(seen == [brain.processIdentifier], "a watched host is reported once")
        watch.stop()
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

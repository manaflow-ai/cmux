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

    /// A fresh home has no lock file, so arming can watch only the folder. Arming again (what a
    /// folder event does) must **keep** that folder source and add only what is missing. An arm
    /// that cancelled and reopened it would leave a window where the lock's creation raises no
    /// event at all, and the pid written afterwards would reach nobody.
    @Test func armingAgainKeepsTheFolderSourceAndAddsTheLockFile() async throws {
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
        // No lock file: the folder is the only thing that can be opened.
        watch.watch(nil)
        #expect(watch.lockSourceOpens == 1, "only the folder is there to watch")
        #expect(seen.isEmpty, "no lock yet: nothing to report")

        // A folder event with the lock still absent: nothing to add, and the folder source stays.
        watch.armOnLock()
        #expect(watch.lockSourceOpens == 1, "the folder source is kept, not cancelled and reopened")

        // The host creates the lock, empty, and writes its pid only afterwards. The folder source
        // that survived hears the creation and adds the file's source for that later write.
        try Data().write(to: lock)
        let armed = ContinuousClock.now + .seconds(5)
        while watch.lockSourceOpens < 2, ContinuousClock.now < armed {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(watch.lockSourceOpens == 2, "the created lock is watched too")
        #expect(seen.isEmpty, "an empty lock names no host")
        try Data("\(brain.processIdentifier)\n".utf8).write(to: lock)
        let deadline = ContinuousClock.now + .seconds(5)
        while seen.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(seen == [brain.processIdentifier], "the pid written after the lock's creation is watched")
        watch.stop()
    }

    /// A launch that printed its pid is watched straight away, but the host writes that pid into
    /// the lock a moment later, and a reader of the brain's liveness (Home's default Chief) reads
    /// the lock, not the process. So the lock watch must stay armed until the lock names the host,
    /// and the write that names it must tell the reader again — otherwise Auto reads "no local
    /// Chief" and stays on the Hosted one for the whole launch (review of #23984).
    @Test func aLaunchPIDWhoseLockComesLaterTellsTheReaderAgain() async throws {
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
        let isHost: (pid_t) -> Bool = { $0 == brain.processIdentifier }
        var seen: [pid_t?] = []
        let watch = ChiefBrainWatch(home: home, restart: { nil }, watching: { seen.append($0) },
                                    isChiefHost: isHost)
        // The shell printed the pid; nothing holds the lock yet.
        #expect(ChiefHostStop.runningHostPID(home: home, isChiefHost: isHost) == nil)
        watch.watch(brain.processIdentifier)
        #expect(seen == [brain.processIdentifier], "the pid is watched at once")
        #expect(watch.lockSourceOpens >= 1, "the lock watch stays armed for the lock still to come")

        // The host takes the lock, which is what a reader of its liveness looks at.
        try Data("\(brain.processIdentifier)\n".utf8).write(to: state.appendingPathComponent("host.lock"))
        let deadline = ContinuousClock.now + .seconds(5)
        while seen.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(seen == [brain.processIdentifier, brain.processIdentifier],
                "the reader is told again once the lock names the host")
        // The lock is readable now, so nothing is left watching it.
        let opens = watch.lockSourceOpens
        try Data("x".utf8).write(to: state.appendingPathComponent("other"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(watch.lockSourceOpens == opens, "the lock watch ends once the lock names the host")
        #expect(seen.count == 2, "and reports nothing more")
        watch.stop()
    }

    /// ``ChiefBrainWatch.armOnLock`` hops to the main actor, so a folder event can be queued before
    /// the lock file's event finds the host and run after it. Such a late arm must open nothing:
    /// otherwise every folder change for the rest of the host's life reopens both descriptors and
    /// does that work on the main thread.
    @Test func anArmQueuedBeforeDiscoveryOpensNothingAfterIt() async throws {
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
        // A lock an earlier host left, so both sources arm.
        try Data("999999\n".utf8).write(to: lock)
        var seen: [pid_t?] = []
        let watch = ChiefBrainWatch(home: home, restart: { nil }, watching: { seen.append($0) },
                                    isChiefHost: { $0 == brain.processIdentifier })
        watch.watch(nil)
        #expect(watch.lockSourceOpens == 2, "the folder and the stale lock are both watched")

        try Data("\(brain.processIdentifier)\n".utf8).write(to: lock)
        let deadline = ContinuousClock.now + .seconds(5)
        while seen.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(seen == [brain.processIdentifier], "the host that took the lock is watched")

        // The folder event the main actor had already queued now runs, with a host watched.
        let opens = watch.lockSourceOpens
        watch.armOnLock()
        #expect(watch.lockSourceOpens == opens, "an arm after discovery opens no descriptor")
        #expect(seen == [brain.processIdentifier], "and reports nothing more")
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

import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextDaemon

/// A retry whose daemon socket's folder does not exist yet (a first launch, the Feed's acpmux
/// reader before acpmux ran) wakes when the socket appears, through the one shared ``RetryWake``
/// watch. Each race is made at the exact point it needs (``RetryWakeProbe/folderChosen``: the
/// folder to watch is chosen and opened, its watch is not live yet), so each test fails on a
/// watch that does not check again after arming. The 10 s deadlines only end a failing run.
@Suite(.timeLimit(.minutes(1))) struct RetryWakeFolderTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("retry-wake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// True on the first ``take()`` only.
    private final class Once: Sendable {
        private let taken = Mutex(false)

        func take() -> Bool {
            taken.withLock { taken -> Bool in
                defer { taken = true }
                return !taken
            }
        }
    }

    /// A probe whose `folderChosen` runs `act` on its first call only (the first arm).
    private func onFirstArm(_ act: @escaping @Sendable () -> Void) -> RetryWakeProbe {
        let once = Once()
        return RetryWakeProbe(folderChosen: { _ in
            if once.take() { act() }
        })
    }

    /// The socket's folder made between choosing its parent and arming the parent's watch: the
    /// socket's event goes to the new folder, so the watch must move down to it.
    @Test func aFolderMadeWhileTheWatchIsArmedIsFollowedToTheSocket() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let socket = home.appendingPathComponent("acpmux.sock").path
        let wake = RetryWake(owner: "RetryWakeFolderTests", probe: onFirstArm {
            try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        })
        wake.watch(file: socket)
        #expect(wake.rebaseline() == .missing)
        #expect(FileManager.default.createFile(atPath: socket, contents: Data()))
        let cause = await wake.awaitWake(delay: .seconds(10), clock: ContinuousClock())
        #expect(cause == .socket, "the socket made in a folder that appeared while arming did not wake the wait")
    }

    /// The socket itself made while arming: no event will come for it, so the armed watch must
    /// see it at once (a pending wake, no timer needed).
    @Test func aSocketMadeWhileTheWatchIsArmedWakesAtOnce() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let socket = home.appendingPathComponent("acpmux.sock").path
        let wake = RetryWake(owner: "RetryWakeFolderTests", probe: onFirstArm {
            try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
            _ = FileManager.default.createFile(atPath: socket, contents: Data())
        })
        wake.watch(file: socket)
        // A zero delay: a pending wake returns first, else the timer does.
        let cause = await wake.awaitWake(delay: .zero, clock: ContinuousClock())
        #expect(cause == .socket, "the socket made while arming left no pending wake")
    }

    /// The watched folder removed and made again while arming: the open descriptor watches the
    /// dead folder, and the same path string hides it, so the watch must compare identities.
    @Test func aFolderReplacedWhileTheWatchIsArmedIsWatchedAgain() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        let socket = home.appendingPathComponent("acpmux.sock").path
        let wake = RetryWake(owner: "RetryWakeFolderTests", probe: onFirstArm {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        })
        wake.watch(file: socket)
        #expect(wake.rebaseline() == .missing)
        #expect(FileManager.default.createFile(atPath: socket, contents: Data()))
        let cause = await wake.awaitWake(delay: .seconds(10), clock: ContinuousClock())
        #expect(cause == .socket, "the socket made in the replaced folder did not wake the wait")
    }

    /// Two missing folders made after the watch is live, one by one: the watch moves down twice.
    @Test func aSocketTwoMissingFoldersDownWakesTheWait() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("a/b", isDirectory: true)
        let socket = home.appendingPathComponent("acpmux.sock").path
        let wake = RetryWake(owner: "RetryWakeFolderTests")
        wake.watch(file: socket)
        #expect(wake.rebaseline() == .missing)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        #expect(FileManager.default.createFile(atPath: socket, contents: Data()))
        let cause = await wake.awaitWake(delay: .seconds(10), clock: ContinuousClock())
        #expect(cause == .socket)
        guard case .present = wake.rebaseline() else {
            Issue.record("the socket that woke the wait is not present")
            return
        }
    }

    /// A folder on the way that exists but does not open (no read permission: mode 0311, still
    /// searchable, so connect works in it): its entries reach no watch above it, so the file is not
    /// "missing and watched" and the wait keeps its timer. Once the folder opens (same identity, a
    /// chmod), the next rebaseline watches it. Before, the watch stayed above it and parked the wait
    /// with no timer, and the socket made in it woke nothing.
    @Test func aFolderOnTheWayThatDoesNotOpenIsNotWatchedThrough() async throws {
        let root = try scratch()
        let blocked = root.appendingPathComponent("blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o311], ofItemAtPath: blocked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path)
            try? FileManager.default.removeItem(at: root)
        }
        let socket = blocked.appendingPathComponent("acpmux.sock").path
        let wake = RetryWake(owner: "RetryWakeFolderTests")
        wake.watch(file: socket)
        #expect(wake.rebaseline() == .unwatched, "a socket behind a folder that does not open counted as watched")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path)
        #expect(wake.rebaseline() == .missing, "the folder that opens now was not watched")
        #expect(FileManager.default.createFile(atPath: socket, contents: Data()))
        let cause = await wake.awaitWake(delay: .seconds(10), clock: ContinuousClock())
        #expect(cause == .socket, "the socket made in the folder that opened did not wake the wait")
    }

    /// ``RetryWake/unwatch()`` ends the watch: nothing is watched until the next watch.
    @Test func unwatchEndsTheWatch() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let wake = RetryWake(owner: "RetryWakeFolderTests")
        wake.watch(file: root.appendingPathComponent("acpmux.sock").path)
        #expect(wake.rebaseline() == .missing)
        wake.unwatch()
        #expect(wake.rebaseline() == .unwatched)
    }
}

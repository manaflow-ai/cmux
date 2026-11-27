@testable import CmuxNextControl
import CmuxNextCompat
import Darwin
import Foundation
import Testing

/// The compatibility link lives in /tmp, which every process on the Mac writes. Watching the
/// link's directory woke the app (one `lstat` on the accept queue) for every file any process
/// created, renamed or deleted in /tmp: idle wakeups caused by other apps
/// (plans/cmux-next/idle-wakeups.md). The watch follows the link itself, so writes beside it
/// wake nothing, and a deleted link still comes back, again and again.
@Suite(.serialized, .timeLimit(.minutes(1))) struct ControlSocketPathWatchIdleTests {
    /// A fresh directory with a symlink `link` in it pointing at `target`.
    func directoryWithLink() throws -> (directory: String, link: String, target: String) {
        let directory = NSTemporaryDirectory() + "cspw-\(UUID().uuidString.prefix(8).lowercased())"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let link = directory + "/cmux.sock", target = directory + "/target.sock"
        try #require(symlink(target, link) == 0)
        return (directory, link, target)
    }

    /// Waits up to 5 s for `condition`, re-reading it every 10 ms (a test waiting for another
    /// queue's work, not product code).
    func eventually(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    @Test func writesBesideTheLinkWakeNothing() async throws {
        let (directory, link, target) = try directoryWithLink()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let restores = RestoreCount()
        let watch = ControlSocketPathWatch(path: link, queue: DispatchQueue(label: "test.path-watch")) {
            restores.value.add(1, ordering: .relaxed)
            return symlink(target, link) == 0
        }
        watch.start()
        defer { watch.stop() }
        for index in 0..<50 {
            let other = directory + "/other-\(index)"
            FileManager.default.createFile(atPath: other, contents: Data("x".utf8))
            unlink(other)
        }
        // A fixed quiet window: the scenario is that nothing happens in it.
        try await Task.sleep(for: .milliseconds(300))
        #expect(watch.checks.load(ordering: .relaxed) == 0, "100 writes beside the link woke the watch")

        // Deleted twice: put back twice (the watch follows the new link).
        for round in 1...2 {
            #expect(unlink(link) == 0)
            #expect(try await eventually { restores.value.load(ordering: .relaxed) == round }, "round \(round): the link is not put back")
            var info = stat()
            #expect(try await eventually { lstat(link, &info) == 0 }, "round \(round): no link at the path")
        }
    }

    /// A watch that fell back to the directory (nothing at the path and the restore refused, as
    /// when the link's makeLink loses to another process) stayed on the directory forever,
    /// waking on every write there (on /tmp: every write on the Mac). It now moves to the entry
    /// as soon as an event finds one it can follow, and still notices when that entry goes.
    @Test func aDirectoryWatchMovesToTheEntryOnceOneIsThere() async throws {
        let directory = NSTemporaryDirectory() + "cspw-\(UUID().uuidString.prefix(8).lowercased())"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/cmux.sock"
        let queue = DispatchQueue(label: "test.path-watch")
        let restores = RestoreCount()
        let watch = ControlSocketPathWatch(path: path, queue: queue) {
            restores.value.add(1, ordering: .relaxed)
            return false
        }
        watch.start()
        defer { watch.stop() }
        queue.sync {}  // the watch is installed (on the directory: nothing at the path, the restore refused)
        let checksAtStart = watch.checks.load(ordering: .relaxed)
        let restoresAtStart = restores.value.load(ordering: .relaxed)

        // Someone else's file at the path: the directory event moves the watch onto it. Made with
        // one open(O_CREAT), one directory change: FileManager.createFile writes atomically (a
        // temporary file, then a rename), two events whose second could reach `queue` after
        // `settled` is read below.
        let file = open(path, O_CREAT | O_WRONLY | O_EXCL, 0o600)
        try #require(file >= 0)
        close(file)
        #expect(try await eventually { watch.checks.load(ordering: .relaxed) > checksAtStart })
        queue.sync {}
        let settled = watch.checks.load(ordering: .relaxed)
        for index in 0..<50 {
            let other = directory + "/other-\(index)"
            FileManager.default.createFile(atPath: other, contents: Data("x".utf8))
            unlink(other)
        }
        // A fixed quiet window: the scenario is that nothing happens in it.
        try await Task.sleep(for: .milliseconds(300))
        #expect(watch.checks.load(ordering: .relaxed) == settled, "the watch stayed on the directory")

        #expect(unlink(path) == 0)
        #expect(try await eventually { restores.value.load(ordering: .relaxed) > restoresAtStart }, "the entry's removal was not noticed")
    }

    /// A listening Unix socket at `path` (another app's live socket); its descriptor.
    func liveSocket(at path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        _ = withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { bytes in buffer.copyBytes(from: bytes.prefix(capacity - 1)) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0)
        try #require(listen(descriptor, 1) == 0)
        return descriptor
    }

    /// A classic cmux of the same channel or tag holds the /tmp compatibility link's path with its
    /// live socket: the link cannot be made, a socket cannot be opened, and the watch fell back to
    /// /tmp, waking (one lstat, one failed open) on every write there by any process while both
    /// apps ran. The link's watch now yields: it watches nothing while that socket is there.
    @Test func aLinkPathHeldByAnotherLiveSocketWatchesNothingInTmp() async throws {
        let path = "/tmp/cspw-\(UUID().uuidString.prefix(8).lowercased()).sock"
        let descriptor = try liveSocket(at: path)
        defer { close(descriptor); unlink(path) }
        let queue = DispatchQueue(label: "test.path-watch")
        let watch = ControlSocketPathWatch(path: path, queue: queue, yieldsToHeldPath: true) { true }
        watch.start()
        defer { watch.stop() }
        queue.sync {}
        let settled = watch.checks.load(ordering: .relaxed)
        for index in 0..<50 {
            let other = "/tmp/cspw-other-\(UUID().uuidString.prefix(8).lowercased())-\(index)"
            FileManager.default.createFile(atPath: other, contents: Data("x".utf8))
            unlink(other)
        }
        // A fixed quiet window: the scenario is that nothing happens in it.
        try await Task.sleep(for: .milliseconds(300))
        #expect(watch.checks.load(ordering: .relaxed) == settled, "writes in /tmp woke the link's watch")
    }

    /// This app's own socket at a socket-path override in /tmp keeps its directory watch (the
    /// hq#1870 cleaner case): deleted, it is noticed.
    @Test func anOwnSocketInTmpIsStillPutBackWhenDeleted() async throws {
        let path = "/tmp/cspw-\(UUID().uuidString.prefix(8).lowercased()).sock"
        let descriptor = try liveSocket(at: path)
        defer { close(descriptor); unlink(path) }
        let queue = DispatchQueue(label: "test.path-watch")
        let restores = RestoreCount()
        let watch = ControlSocketPathWatch(path: path, queue: queue) {
            restores.value.add(1, ordering: .relaxed)
            return true
        }
        watch.start()
        defer { watch.stop() }
        queue.sync {}
        #expect(unlink(path) == 0)
        #expect(try await eventually { restores.value.load(ordering: .relaxed) > 0 }, "the deleted socket was not noticed")
    }
}

/// A FIFO at the path: the watch opened whatever was there with a blocking open(2), so a FIFO held the
/// server's accept queue until some process opened it for writing (review of item 6). The open no longer
/// waits, and the queue goes on.
@Suite(.serialized, .timeLimit(.minutes(1))) struct ControlSocketPathWatchFIFOTests {
    @Test func aFIFOAtThePathDoesNotHoldTheQueue() async throws {
        let directory = NSTemporaryDirectory() + "cspw-\(UUID().uuidString.prefix(8).lowercased())"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/cmux.sock"
        try #require(mkfifo(path, 0o600) == 0)
        defer {
            // A blocked open (the bug) ends when a writer opens the FIFO; then the files can go.
            let writer = open(path, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
            try? FileManager.default.removeItem(atPath: directory)
        }
        let queue = DispatchQueue(label: "test.path-watch")
        let watch = ControlSocketPathWatch(path: path, queue: queue) { false }
        watch.start()
        defer { watch.stop() }
        let ran = RestoreCount()
        queue.async { ran.value.store(1, ordering: .relaxed) }
        let deadline = ContinuousClock.now + .seconds(5)
        while ran.value.load(ordering: .relaxed) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))  // a test waiting for another queue, not product code
        }
        #expect(ran.value.load(ordering: .relaxed) == 1, "the watch's open of a FIFO held its queue")
    }
}

/// Restores the watch asked for (a class: an `Atomic` cannot be captured).
final class RestoreCount: Sendable {
    let value = Atomic<Int>(0)
}

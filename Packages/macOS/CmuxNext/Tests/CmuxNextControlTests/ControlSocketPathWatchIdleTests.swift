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
}

/// Restores the watch asked for (a class: an `Atomic` cannot be captured).
final class RestoreCount: Sendable {
    let value = Atomic<Int>(0)
}

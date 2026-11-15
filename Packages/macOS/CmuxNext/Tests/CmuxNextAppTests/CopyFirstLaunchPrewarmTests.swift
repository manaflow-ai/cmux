import CmuxNextCompat
import CmuxNextTestSupport
import CmuxNextWakeups
import Foundation
@testable import CmuxNextUpdater
import Testing

/// A new copy's first launch runs each Chromium helper once with --version from `main` (goal
/// next-launch-instant, CMUX-571), so the framework's first load overlaps the app's start; a copy that
/// already ran starts nothing.
@MainActor @Suite(.serialized) struct CopyFirstLaunchPrewarmTests {
    nonisolated final class Marks: Sendable {
        let names = Mutex<[String]>([])
    }

    /// A copy of the app: its executable and two Chromium helpers, each a script that appends its name to
    /// `<root>/ran.txt`.
    static func copy() throws -> (root: URL, prewarm: CopyFirstLaunchPrewarm) {
        let root = FileManager.default.temporaryDirectory.appending(path: "copy-first-launch-prewarm-\(UUID().uuidString)")
        let app = try StagedUpdatePrewarmTests.stage(root, "a", "b", build: "100", bins: [])
        return (root, CopyFirstLaunchPrewarm(bundle: app, executable: app.appending(path: "Contents/MacOS/cmux")))
    }

    static func ran(_ root: URL) -> [String] {
        ((try? String(contentsOf: root.appending(path: "ran.txt"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init).sorted()
    }

    @Test func aNewCopyRunsEachHelperOnceAndASecondLaunchRunsNothing() async throws {
        let (root, prewarm) = try Self.copy()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(testSuiteName: "CopyFirstLaunchPrewarmTests.\(UUID().uuidString)")!
        let marks = Marks()
        let started = await prewarm.perform(defaults: defaults, processes: AsyncProcess(), timeout: .seconds(20)) { name in
            marks.names.withLock { $0.append(name) }
        }
        #expect(started == 2)
        #expect(Self.ran(root) == ["cmux Helper (GPU) --version", "cmux Helper --version"])
        #expect(marks.names.withLock { $0 } == ["copy_prewarm.start", "copy_prewarm.end"])
        #expect(defaults.string(forKey: CopyFirstLaunchPrewarm.defaultsKey) == prewarm.identity())
        #expect(await prewarm.perform(defaults: defaults, processes: AsyncProcess(), timeout: .seconds(20)) == 0)
        #expect(Self.ran(root).count == 2, "a copy that already ran pre-warmed again")
    }

    @Test func anotherCopyOrAnUpdateHasAnotherIdentity() throws {
        let (root, prewarm) = try Self.copy()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try #require(prewarm.identity())
        #expect(prewarm.plan(identity: first, kept: first).isEmpty)
        #expect(prewarm.plan(identity: first, kept: nil).count == 2)
        // A new copy (ditto out of the DMG, an update's swap): another inode, so it pre-warms again.
        let moved = root.appending(path: "moved")
        try FileManager.default.copyItem(at: prewarm.bundle, to: moved)
        let copy = CopyFirstLaunchPrewarm(bundle: moved, executable: moved.appending(path: "Contents/MacOS/cmux"))
        #expect(copy.identity() != first)
        #expect(copy.plan(identity: copy.identity(), kept: first).count == 2)
        #expect(prewarm.plan(identity: nil, kept: nil).isEmpty, "an unreadable executable starts nothing")
    }
}

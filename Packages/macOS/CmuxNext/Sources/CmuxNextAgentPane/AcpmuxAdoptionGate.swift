import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import os

/// Whether an acpmux lookup waits for this launch's build-home adoption
/// (``AcpmuxEnvironment/adoptBuildHomes()``, cx-is1kf.9) before it asks or starts a home's daemon.
///
/// The adoption moves NEXT's pre-isolation homes in, and stops a running daemon of each home it moves
/// first (cmux-tui `build_adopt`). A lookup that went ahead of it could connect a chat to a daemon the
/// adoption then stops, in a home it then replaces: that is why the lookup waited for it. But a home
/// whose adoption is settled on disk (``mayChange(home:)`` false: its `adopted.json`, or no old home to
/// move in) is never touched by it again, so its lookup goes on at once and the adoption ends in the
/// background with nothing to apply to it. Every relaunch after the first is that case. A home the
/// adoption may still change waits up to ``limit``; then the lookup fails as restarting (a transient
/// failure the page retries, and says once it lasts) rather than waiting in silence.
nonisolated struct AcpmuxAdoptionGate: Sendable {
    /// Whether this launch's adoption may still move or stop `home` (an acpmux home).
    var mayChange: @Sendable (URL) -> Bool
    /// Returns when this launch's adoption ended.
    var untilEnded: @Sendable () async -> Void
    /// How long one lookup waits for an adoption that may change its home.
    var limit: Duration

    /// cmux NEXT's adoption: only NEXT adopts (every other build's adoption returns at once).
    static let live = AcpmuxAdoptionGate(
        mayChange: { home in
            BuildHomeAdoption.applies(bundleID: Bundle.main.bundleIdentifier, environment: ProcessInfo.processInfo.environment)
                && AcpmuxAdoptionGate.mayChange(home: home)
        },
        untilEnded: { await AcpmuxEnvironment.adoptBuildHomes() },
        limit: .seconds(10))

    /// The record an adopted home keeps (cmux-tui `build_adopt::RECORD`): present = done.
    static let record = "adopted.json"
    /// NEXT's acpmux home before per-build isolation: `<acpmux root>/tags/cmux-next` (`build_adopt::LEGACY_TAG`).
    static let legacyTag = "cmux-next"

    /// Whether the adoption may still change `home`, read from disk the way cmux-tui `build_adopt`
    /// decides it has nothing to do:
    /// - a Chief home's acpmux (`<chief root>/<NEXT bundle id>[.<account>]/acpmux`): the Chief
    ///   adoption clones into that Chief home and stops its owner until the Chief home has its record;
    /// - any other home (`<root>/builds/<key>`): the acpmux adoption renames `<root>/tags/cmux-next`
    ///   in while that is a real directory (after it, a link) and the home has no record.
    static func mayChange(home: URL) -> Bool {
        let files = FileManager.checked
        if files.fileExists(atPath: home.appending(path: record, directoryHint: .notDirectory).path) { return false }
        let parent = home.deletingLastPathComponent()
        let next = BuildHomeAdoption.nextBundleID
        if home.lastPathComponent == "acpmux", parent.lastPathComponent == next || parent.lastPathComponent.hasPrefix(next + ".") {
            return !files.fileExists(atPath: parent.appending(path: record, directoryHint: .notDirectory).path)
        }
        let legacy = parent.deletingLastPathComponent()
            .appending(path: "tags", directoryHint: .isDirectory).appending(path: legacyTag, directoryHint: .isDirectory)
        // Not followed: the link an adoption leaves is no home to adopt.
        let type = (try? files.attributesOfItem(atPath: legacy.path))?[.type] as? FileAttributeType
        return type == .typeDirectory
    }

    /// True when the lookup of `home` may go on: at once for a home the adoption no longer changes,
    /// else once the adoption ended; false when it still runs after ``limit``.
    func lookupMayProceed(home: URL) async -> Bool {
        guard mayChange(home) else { return true }
        let untilEnded = self.untilEnded
        let deadline = DemandTimer(owner: "acpmux-adoption-gate")
        let ended: Bool = await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Bool) -> Void = { ended in
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: ended) }
            }
            // task-owner: ends with this launch's adoption, which every lookup shares; its finish after the limit is dropped
            Task { await untilEnded(); finish(true) }
            deadline.schedule(after: limit) { finish(false) }
        }
        deadline.cancel()
        return ended
    }
}

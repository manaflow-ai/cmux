@testable import CmuxNextApp
import Foundation
import Testing

/// GhosttyConfigLiveReload released off the main thread (its last reference dropped on another
/// thread) still removes its config-change observer: its `deinit` used to return early off main,
/// leaving the registration in the notification center for the life of the process.
@MainActor @Suite(.serialized) struct GhosttyConfigLiveReloadReleaseTests {
    @Test func releasedOffMainItRemovesItsObserver() async throws {
        let center = RecordingCenter()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ghostty-live-reload-\(UUID().uuidString)")
        try "font-size = 12\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let box = ReleaseBox()
        do {
            let reload = GhosttyConfigLiveReload(files: { [file.path] }, reload: {}, notifications: center)
            reload.start()
            #expect(center.added == 1)
            box.value = reload
        }
        // The last reference goes away on a thread that is not main.
        await Task.detached { box.value = nil }.value
        #expect(center.removed == 1, "the config-change observer outlived its owner (released off main)")
    }
}

/// A notification center that counts observer registrations and removals.
private nonisolated final class RecordingCenter: NotificationCenter, @unchecked Sendable {
    // Counts only; NotificationCenter is thread-safe and these are read after the release finished.
    private(set) nonisolated(unsafe) var added = 0
    private(set) nonisolated(unsafe) var removed = 0

    override func addObserver(forName name: NSNotification.Name?, object obj: Any?, queue: OperationQueue?,
                              using block: @escaping @Sendable (Notification) -> Void) -> any NSObjectProtocol {
        added += 1
        return super.addObserver(forName: name, object: obj, queue: queue, using: block)
    }

    override func removeObserver(_ observer: Any) {
        removed += 1
        super.removeObserver(observer)
    }
}

/// Holds the only reference, so dropping it on another thread runs the deinit there.
private nonisolated final class ReleaseBox: @unchecked Sendable {
    // Written once on main, then cleared once on the detached task; never concurrently.
    nonisolated(unsafe) var value: AnyObject?
}

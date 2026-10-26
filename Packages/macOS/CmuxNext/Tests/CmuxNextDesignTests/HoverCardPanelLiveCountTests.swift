import AppKit
import CmuxNextCompat
@testable import CmuxNextDesign
import Testing

/// `HoverCardPanel.liveInstances` feeds the single-card check (`debug.desync`, `card_windows`): it
/// counts every card window from its init to its deinit. The count is an atomic, so the deinit,
/// which may run off the main thread, takes the window off the count wherever it runs.
@MainActor @Suite(.serialized) struct HoverCardPanelLiveCountTests {
    @Test func aCardWindowCountsFromItsInitUntilItIsReleased() {
        let before = HoverCardPanel.liveInstances.load(ordering: .relaxed)
        autoreleasepool {
            let panel = HoverCardPanel()
            withExtendedLifetime(panel) {
                #expect(HoverCardPanel.liveInstances.load(ordering: .relaxed) == before + 1)
            }
        }
        #expect(HoverCardPanel.liveInstances.load(ordering: .relaxed) == before, "a released card window still counts")
    }

    /// The release on another thread: before, the deinit returned early off the main thread and the
    /// window stayed counted for the rest of the run.
    @Test func aCardWindowReleasedOffTheMainThreadLeavesTheCount() async {
        let before = HoverCardPanel.liveInstances.load(ordering: .relaxed)
        let box = PanelBox(HoverCardPanel())
        #expect(HoverCardPanel.liveInstances.load(ordering: .relaxed) == before + 1)
        await Task.detached(priority: .userInitiated) { box.release() }.value
        #expect(HoverCardPanel.liveInstances.load(ordering: .relaxed) == before, "a card released off main still counts")
    }
}

/// Hands the one strong reference to a background task, which drops it there.
private nonisolated final class PanelBox: Sendable {
    private let panel: Mutex<HoverCardPanel?>

    init(_ panel: sending HoverCardPanel) { self.panel = Mutex(panel) }

    func release() { panel.withLock { $0 = nil } }
}

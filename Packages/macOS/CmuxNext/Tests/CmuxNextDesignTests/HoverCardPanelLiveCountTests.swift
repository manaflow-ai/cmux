import AppKit
import CmuxNextCompat
@testable import CmuxNextDesign
import Testing

/// `HoverCardPanel.liveInstances` feeds the single-card check (`debug.desync`, `card_windows`): it
/// counts every card window from its init to its deinit, wherever the deinit runs. Each test counts
/// its panel on its own `WindowCount`, so cards that other suites make or free meanwhile do not
/// move it.
@MainActor @Suite struct HoverCardPanelLiveCountTests {
    @Test func aCardWindowCountsFromItsInitUntilItIsReleased() {
        let count = WindowCount()
        autoreleasepool {
            let panel = HoverCardPanel(countWindow: count.move)
            withExtendedLifetime(panel) {
                #expect(count.current == 1)
            }
        }
        #expect(count.current == 0, "a released card window still counts")
    }

    /// Before, the deinit returned early off the main thread and the window stayed counted for the
    /// rest of the run.
    @Test func aCardWindowReleasedOffTheMainThreadLeavesTheCount() async {
        let count = WindowCount()
        // The pool drains any reference AppKit autoreleased during init: the box holds the only one.
        let box = autoreleasepool { PanelBox(countWindow: count.move) }
        #expect(count.current == 1)
        let release = await Task.detached(priority: .userInitiated) {
            let onMain = pthread_main_np() != 0
            let freed = box.release()
            return (onMain: onMain, freed: freed, left: count.current)
        }.value
        #expect(!release.onMain)
        #expect(release.freed, "the window was not freed by the release off the main thread")
        #expect(release.left == 0, "a card released off main still counts")
    }
}

/// One test's count of card windows.
private nonisolated final class WindowCount: Sendable {
    private let value = Atomic<Int>(0)

    var current: Int { value.load(ordering: .relaxed) }

    @Sendable func move(_ delta: Int) { value.add(delta, ordering: .relaxed) }
}

/// Hands the one strong reference to a background task, which drops it there.
private nonisolated final class PanelBox: Sendable {
    private nonisolated struct Slot: Sendable {
        var panel: HoverCardPanel?
        weak var watched: HoverCardPanel?
    }

    private let slot: Mutex<Slot>

    /// Makes the panel here, so it starts in a region of its own that the box can take.
    @MainActor init(countWindow: @escaping @Sendable (Int) -> Void) {
        let panel = HoverCardPanel(countWindow: countWindow)
        slot = Mutex(Slot(panel: panel, watched: panel))
    }

    /// Drops the strong reference on the calling thread; true when that freed the window there.
    func release() -> Bool {
        slot.withLock { slot in
            slot.panel = nil
            return slot.watched == nil
        }
    }
}

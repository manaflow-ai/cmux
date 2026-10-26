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
        let box = autoreleasepool { PanelBox(HoverCardPanel(countWindow: count.move)) }
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
    private let lock = Mutex(())
    // A main-actor init's panel stays in main's region, so a `sending` or Mutex hand-off is refused.
    // crash-allow: test only; the box holds the only strong reference and reads or drops it under `lock` alone
    private nonisolated(unsafe) var panel: HoverCardPanel?
    // crash-allow: test only; read under `lock` alone, after the strong reference is dropped
    private nonisolated(unsafe) weak var watched: HoverCardPanel?

    /// Takes the panel; the caller keeps no other reference to it.
    @MainActor init(_ panel: HoverCardPanel) {
        self.panel = panel
        watched = panel
    }

    /// Drops the strong reference on the calling thread; true when that freed the window there.
    func release() -> Bool {
        lock.withLock { _ in
            unsafe panel = nil
            return unsafe watched == nil
        }
    }
}

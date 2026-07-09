import Foundation
import Testing
@testable import CmuxCommandPalette

@MainActor
@Suite("CommandPalettePresentationCoordinator")
struct CommandPalettePresentationCoordinatorTests {
    /// A manual clock so timing-sensitive assertions are deterministic.
    private final class ManualClock {
        var now: TimeInterval = 0
    }

    private func makeCoordinator(
        clock: ManualClock = ManualClock()
    ) -> CommandPalettePresentationCoordinator {
        CommandPalettePresentationCoordinator(
            effects: .noop,
            now: { clock.now }
        )
    }

    @Test("postRequest clears browser focus, marks pending, then posts in order")
    func postRequestOrder() {
        let clock = ManualClock()
        clock.now = 100
        let coordinator = makeCoordinator(clock: clock)
        let id = UUID()
        var events: [String] = []

        coordinator.postRequest(
            kind: .commands,
            windowId: id,
            source: "test",
            debugTarget: "win",
            clearBrowserFocusMode: { events.append("clear") },
            post: { events.append("post") }
        )

        #expect(events == ["clear", "post"])
        // .commands marks pending, so the window is pending-open right after.
        #expect(coordinator.isPendingOpen(id) == true)
    }

    @Test("postRequest with nil windowId still clears and posts but marks nothing")
    func postRequestNilWindow() {
        let coordinator = makeCoordinator()
        var cleared = false
        var posted = false

        coordinator.postRequest(
            kind: .commands,
            windowId: nil,
            source: "test",
            debugTarget: "nil",
            clearBrowserFocusMode: { cleared = true },
            post: { posted = true }
        )

        #expect(cleared)
        #expect(posted)
        #expect(coordinator.firstPendingOpenWindowId() == nil)
    }

    @Test("pending-open is live within grace and pruned past max age")
    func pendingPruning() {
        let clock = ManualClock()
        clock.now = 100
        let coordinator = makeCoordinator(clock: clock)
        let id = UUID()

        coordinator.markOpenRequested(id)
        #expect(coordinator.isPendingOpen(id) == true)
        #expect(coordinator.recentRequestAge(id) == 0)

        clock.now = 100 + CommandPaletteWindowStore.pendingOpenMaxAge + 0.01
        #expect(coordinator.isPendingOpen(id) == false)
    }

    @Test("escape suppression is consumed within the suppression interval only")
    func escapeSuppression() {
        let clock = ManualClock()
        clock.now = 100
        let coordinator = makeCoordinator(clock: clock)
        let id = UUID()

        coordinator.beginEscapeSuppression(id)
        #expect(coordinator.shouldConsumeSuppressedEscape(id) == true)

        clock.now = 100 + CommandPaletteWindowStore.escapeSuppressionInterval + 0.01
        #expect(coordinator.shouldConsumeSuppressedEscape(id) == false)
    }

    @Test("setVisible clears focus on open and posts only when the value flips")
    func setVisibleFlipPosting() {
        let coordinator = makeCoordinator()
        let id = UUID()
        coordinator.registerWindow(id)
        var clears = 0
        var posts: [Bool] = []

        // false -> false: no flip, no post; not visible so no clear.
        coordinator.setVisible(
            false, for: id, debugWindow: "win",
            clearBrowserFocusMode: { clears += 1 },
            postVisibilityDidChange: { posts.append($0) }
        )
        #expect(clears == 0)
        #expect(posts.isEmpty)

        // false -> true: flip + open clears focus.
        coordinator.setVisible(
            true, for: id, debugWindow: "win",
            clearBrowserFocusMode: { clears += 1 },
            postVisibilityDidChange: { posts.append($0) }
        )
        #expect(clears == 1)
        #expect(posts == [true])
        #expect(coordinator.isVisible(id) == true)

        // true -> false: flip, no clear (only opens clear).
        coordinator.setVisible(
            false, for: id, debugWindow: "win",
            clearBrowserFocusMode: { clears += 1 },
            postVisibilityDidChange: { posts.append($0) }
        )
        #expect(clears == 1)
        #expect(posts == [true, false])
        #expect(coordinator.isVisible(id) == false)
    }

    @Test("setVisible(true) resolves an in-flight pending-open request")
    func setVisibleResolvesPending() {
        let coordinator = makeCoordinator()
        let id = UUID()
        coordinator.markOpenRequested(id)
        #expect(coordinator.isPendingOpen(id) == true)

        coordinator.setVisible(
            true, for: id, debugWindow: "win",
            clearBrowserFocusMode: {},
            postVisibilityDidChange: { _ in }
        )
        #expect(coordinator.isPendingOpen(id) == false)
    }
}

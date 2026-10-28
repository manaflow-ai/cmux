import CmuxNextAgentActivity
@testable import CmuxNextApp
import CmuxNextWakeups
import Observation
import Testing

/// A jump to a chat in a workspace whose panes have not mounted waits for the first pane
/// (``AgentChatPaneWait``, what `AgentActivityPageService` runs): it opens the chat once when a
/// pane mounts, in the same turn when one is there already, on the next frame otherwise; it opens
/// nothing when the window closes or shows another workspace, or when a newer jump replaced it.
@MainActor
struct AgentChatPaneWaitTests {
    /// The jump's window as the wait reads it.
    @Observable @MainActor
    final class Window {
        var showing: String? = "ws-1"
        var hasPane = false
    }

    private static func wait(_ window: Window, frames: NotificationFrames, opened: @escaping () -> Void) -> AgentChatPaneWait {
        AgentChatPaneWait(on: frames.work) {
            .decide(showing: window.showing, workspaceID: "ws-1", hasPane: window.hasPane)
        } open: {
            opened()
        }
    }

    @Test func aPaneMountedInTheJumpsTurnOpensAtOnce() {
        let frames = NotificationFrames()
        let window = Window()
        window.hasPane = true
        var opens = 0
        let wait = Self.wait(window, frames: frames) { opens += 1 }
        #expect(opens == 1)
        #expect(wait.isOver)
    }

    @Test func aPaneThatMountsLaterOpensOnceOnTheNextFrame() {
        let frames = NotificationFrames()
        let window = Window()
        var opens = 0
        let wait = Self.wait(window, frames: frames) { opens += 1 }
        frames.frame()
        #expect(opens == 0 && !wait.isOver, "no pane yet: it waits")
        window.hasPane = true
        #expect(opens == 0, "it opened in the mount's own turn")
        frames.frame()
        #expect(opens == 1)
        #expect(wait.isOver)
        // Later mounts open nothing more.
        window.hasPane = false
        frames.frame()
        window.hasPane = true
        frames.frame()
        #expect(opens == 1)
    }

    @Test func aClosedWindowOrAnotherWorkspaceEndsTheWaitWithNothingOpened() {
        let leaves: [(Window) -> Void] = [{ $0.showing = nil }, { $0.showing = "ws-2" }]
        for leave in leaves {
            let frames = NotificationFrames()
            let window = Window()
            var opens = 0
            let wait = Self.wait(window, frames: frames) { opens += 1 }
            leave(window)
            frames.frame()
            #expect(wait.isOver)
            window.showing = "ws-1"
            window.hasPane = true
            frames.frame()
            #expect(opens == 0, "a wait that ended opened the chat")
        }
    }

    @Test func aNewerJumpReplacesTheWait() {
        let frames = NotificationFrames()
        let window = Window()
        var opens = 0
        let wait = Self.wait(window, frames: frames) { opens += 1 }
        wait.cancel()
        window.hasPane = true
        frames.frame()
        #expect(opens == 0, "a replaced wait opened the chat")
        #expect(wait.isOver)
    }
}

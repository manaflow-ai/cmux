import AppKit
@testable import CmuxNextAgentPane
import CmuxNextTestSupport
import Testing

/// Only a window the person can see counts (review of #39700, F1): a page in a window that is ordered out or has
/// none holds no spare.
@MainActor @Suite(.closesItsWindows) struct AgentPaneShownChatsWindowTests {
    @Test func aWindowOrderedOutOrMissingIsNotShown() {
        #expect(!AgentPaneShownChatsWait.shown(nil))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        #expect(!AgentPaneShownChatsWait.shown(window), "a window never ordered in counted as shown")
    }
}

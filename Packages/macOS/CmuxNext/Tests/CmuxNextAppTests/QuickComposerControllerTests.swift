import AppKit
import CmuxNextAgentPane
@testable import CmuxNextApp
import Testing

/// Quick Agent Chat: one toggle for every entrypoint, a chat that keeps its
/// draft while hidden, and a hand-off that starts the next show fresh.
@MainActor
struct QuickComposerControllerTests {
    final class FakeWindow: QuickComposerWindow {
        var isVisible = false
        var isKeyWindow = false
        var onResignKey: (() -> Void)?
        var onCancel: (() -> Void)?
        var shown: [NSView] = []

        func present(_ content: NSView, focus: NSView?) {
            shown.append(content)
            isVisible = true
            isKeyWindow = true
        }

        func dismiss() {
            isVisible = false
            isKeyWindow = false
        }
    }

    final class Harness {
        let window = FakeWindow()
        var chatsMade = 0
        var opened: [String?] = []
        var started: [AgentPaneQuickStart] = []
        var canHostChat = true
        var canOpen = true
        lazy var controller = QuickComposerController(
            makeChat: { [unowned self] in
                guard self.canHostChat else { return nil }
                self.chatsMade += 1
                return AgentPaneView(model: AgentPaneModel(host: MockAgentPaneHost()))
            },
            makeWindow: { [unowned self] in self.window },
            openInWindow: { [unowned self] session in
                self.opened.append(session)
                return self.canOpen
            },
            startInBackground: { [unowned self] start in
                self.started.append(start)
                return self.canOpen
            }
        )
    }

    @Test func toggleShowsThenHidesTheSameChat() throws {
        let harness = Harness()
        let controller = harness.controller
        controller.toggle()
        #expect(harness.window.isVisible)
        let chat = try #require(controller.chat)

        controller.toggle()
        #expect(!harness.window.isVisible)
        #expect(controller.chat === chat, "the hidden chat keeps its draft")

        controller.toggle()
        #expect(harness.window.isVisible)
        #expect(harness.window.shown.allSatisfy { $0 === chat })
        #expect(harness.chatsMade == 1)
    }

    /// Visible without the keys (another app took them): the next toggle
    /// brings it back with the keys instead of hiding it.
    @Test func aPanelWithoutTheKeysIsShownAgain() {
        let harness = Harness()
        harness.controller.toggle()
        harness.window.isKeyWindow = false
        harness.controller.toggle()
        #expect(harness.window.isVisible)
        #expect(harness.window.isKeyWindow)
    }

    @Test func escapeAClickAwayAndThePageHideIt() throws {
        let harness = Harness()
        let controller = harness.controller
        controller.show()
        harness.window.onResignKey?()
        #expect(!controller.isShown)

        controller.show()
        harness.window.onCancel?()
        #expect(!controller.isShown)

        controller.show()
        let model = try #require(controller.chat?.model)
        model.onQuickDismiss?()
        #expect(!controller.isShown)
        #expect(controller.chat != nil)
    }

    @Test func openInWindowHandsOffTheSessionAndStartsOver() async throws {
        let harness = Harness()
        let controller = harness.controller
        controller.show()
        let model = try #require(controller.chat?.model)
        _ = await model.respond(to: .persistSession("s-1"))
        _ = await model.respond(to: .quickOpenInWindow(sessionId: nil))
        #expect(harness.opened == ["s-1"])
        #expect(!controller.isShown)
        #expect(controller.chat == nil)

        controller.show()
        #expect(harness.chatsMade == 2)
        #expect(controller.chat?.model.sessionId == nil)
    }

    @Test func aHandOffWithNowhereToOpenKeepsTheChat() async throws {
        let harness = Harness()
        harness.canOpen = false
        let controller = harness.controller
        controller.show()
        let chat = try #require(controller.chat)
        _ = await chat.model.respond(to: .persistSession("s-1"))
        _ = await chat.model.respond(to: .quickOpenInWindow(sessionId: nil))
        #expect(harness.opened == ["s-1"])
        #expect(controller.chat === chat)
    }

    /// Start Agent's Return (cx-hkat): the started chat goes to the
    /// sidebar in the background, the panel hides without bringing a window
    /// forward, and the next show is a fresh chat.
    @Test func returnStartsTheChatInTheBackgroundAndStartsOver() async throws {
        let harness = Harness()
        let controller = harness.controller
        controller.show()
        let model = try #require(controller.chat?.model)
        let start = AgentPaneQuickStart(sessionId: "s-9", cwd: "/repo", name: "fix the flaky test")
        _ = await model.respond(to: .quickStartInBackground(start))
        #expect(harness.started == [start])
        #expect(harness.opened.isEmpty)
        #expect(!controller.isShown)
        #expect(controller.chat == nil)

        controller.show()
        #expect(harness.chatsMade == 2)
        #expect(controller.chat?.model.sessionId == nil)
    }

    /// Nowhere to put the session (daemon offline, the workspace failed):
    /// the panel comes back with the chat, so the session stays reachable.
    @Test func aBackgroundStartWithNowhereToGoShowsTheChatAgain() async throws {
        let harness = Harness()
        harness.canOpen = false
        let controller = harness.controller
        controller.show()
        let chat = try #require(controller.chat)
        _ = await chat.model.respond(to: .quickStartInBackground(AgentPaneQuickStart(sessionId: "s-9", cwd: nil, name: nil)))
        #expect(controller.chat === chat)
        #expect(controller.isShown)
    }

    @Test func aBuildWithoutTheAgentPageShowsNothing() {
        let harness = Harness()
        harness.canHostChat = false
        harness.controller.toggle()
        #expect(!harness.window.isVisible)
        #expect(harness.controller.chat == nil)
    }

    @Test func thePanelSitsCenteredAQuarterDownTheScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let frame = QuickComposerPanel.placement(size: QuickComposerPanel.size, in: visible)
        #expect(frame.midX == visible.midX)
        #expect(frame.maxY == CGFloat(750))
        #expect(frame.size == QuickComposerPanel.size)

        let small = CGRect(x: 100, y: 50, width: 500, height: 200)
        let clamped = QuickComposerPanel.placement(size: QuickComposerPanel.size, in: small)
        #expect(clamped.width == CGFloat(500))
        #expect(clamped.minY >= small.minY)
    }
}

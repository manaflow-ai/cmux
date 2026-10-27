import AppKit
@testable import CmuxNextAgentPane
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextApp
@testable import CmuxNextFloating

/// Start Agent's floating chat (cx-b9qi). With it on, the chat the page starts
/// stays in the panel and keeps running there, and the panel stays up when
/// another window takes the keys; with it off, Start Agent hands the chat to
/// the sidebar as before. Each test sends the page's own
/// `quick.startInBackground` through a real agent page's model.
@MainActor
struct FloatingChatTests {
    final class FakeWindow: QuickComposerWindow {
        var isVisible = false
        var isKeyWindow = false
        var onResignKey: (() -> Void)?
        var onCancel: (() -> Void)?
        var held: [Bool] = []
        var onTop = true
        var collapsed = false

        func present(_ content: NSView, focus: NSView?) {
            isVisible = true
            isKeyWindow = true
        }

        func dismiss() {
            isVisible = false
            isKeyWindow = false
        }

        func holdChat(_ holds: Bool) { held.append(holds) }
        func setOnTop(_ onTop: Bool) { self.onTop = onTop }
        func setCollapsed(_ collapsed: Bool) { self.collapsed = collapsed }

        /// A click in another window or app.
        func loseKeys() {
            isKeyWindow = false
            onResignKey?()
        }
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    final class Rig {
        let window = FakeWindow()
        var handedOff: [String] = []
        var opened: [String?] = []
        /// The floating states pushed to the page, in order.
        var pushed: [AgentPaneFloatingState] = []
        /// The session each made chat was bound to (nil: a new chat).
        var made: [String?] = []
        /// What the user is looking at in cmux, for Include focused tab.
        var focused: AgentPaneQuickContext?
        /// Weak: the controller's closures hold the rig, and the rig's deinit clears its defaults.
        weak var controller: QuickComposerController?
        /// This launch's user defaults; a relaunch passes the same suite.
        let suite: String
        let defaults: UserDefaults

        /// The first launch on a suite owns it and removes it when done.
        let ownsSuite: Bool

        init(suite: String, ownsSuite: Bool) {
            self.suite = suite
            self.ownsSuite = ownsSuite
            defaults = UserDefaults(suiteName: suite) ?? .standard
        }

        deinit {
            if ownsSuite { UserDefaults.standard.removePersistentDomain(forName: suite) }
        }
    }

    static func rig(floating: Bool, suite: String? = nil) throws -> (Rig, QuickComposerController) {
        let page = try #require(AgentPageAppTestRoot.page)
        let rig = Rig(suite: suite ?? "floating-chat-\(UUID().uuidString)", ownsSuite: suite == nil)
        let controller = QuickComposerController(
            makeChat: { session in
                rig.made.append(session)
                return AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: session), work: BackgroundWork(label: "test.agent-pane"), source: .bundled(page), webUI: .agentTabsTestHost(), gestures: .testing())
            },
            makeWindow: { rig.window },
            openInWindow: { session in
                rig.opened.append(session)
                return true
            },
            startInBackground: { start in
                rig.handedOff.append(start.sessionId)
                return true
            },
            floating: { floating },
            pushState: { state, _ in rig.pushed.append(state) },
            context: { rig.focused },
            defaults: rig.defaults,
            mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        rig.controller = controller
        return (rig, controller)
    }

    /// What the page sends once acpmux took the first prompt.
    static func started(_ session: String) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "quick.startInBackground",
                                "params": ["sessionId": session, "cwd": "/tmp", "name": "Fix the flaky upload test"]])
    }

    @Test func aStartedChatStaysInTheFloatingPanelAndKeepsItsSession() async throws {
        let (rig, controller) = try Self.rig(floating: true)
        controller.show()
        let chat = try #require(controller.chat)
        _ = await chat.model.respond(to: Self.started("session-1"))

        #expect(rig.handedOff.isEmpty, "the chat went to the sidebar")
        #expect(rig.window.isVisible, "the panel hid")
        #expect(controller.chat === chat, "the panel let go of the chat")
        #expect(chat.model.sessionId == "session-1")
        #expect(rig.window.held == [true], "the panel did not become the floating chat")

        // A later prompt in the same chat sends the same message again: it stays.
        _ = await chat.model.respond(to: Self.started("session-1"))
        #expect(rig.handedOff.isEmpty)
        #expect(rig.window.isVisible)
    }

    @Test func theFloatingChatStaysUpWhenAnotherWindowTakesTheKeys() async throws {
        let (rig, controller) = try Self.rig(floating: true)
        controller.show()
        // A draft still goes away on a click elsewhere, as Start Agent's does.
        rig.window.loseKeys()
        #expect(!rig.window.isVisible)

        controller.show()
        let chat = try #require(controller.chat)
        _ = await chat.model.respond(to: Self.started("session-2"))
        rig.window.loseKeys()
        #expect(rig.window.isVisible, "the running chat's panel hid on a click elsewhere")

        // Esc or the toggle key still put it away, and the next show brings back the same chat.
        controller.hide()
        #expect(!rig.window.isVisible)
        controller.show()
        #expect(rig.window.isVisible)
        #expect(controller.chat === chat)
    }

    @Test func movingTheFloatingChatToATabKeepsItsSessionAndResetsThePanel() async throws {
        let (rig, controller) = try Self.rig(floating: true)
        controller.show()
        let chat = try #require(controller.chat)
        _ = await chat.model.respond(to: Self.started("session-3"))
        _ = await chat.model.respond(to: AgentPaneRequest(body: ["method": "quick.openInWindow", "params": ["sessionId": "session-3"]]))

        #expect(rig.opened == ["session-3"])
        #expect(!rig.window.isVisible)
        #expect(rig.window.held == [true, false], "the panel stayed the floating chat")
        controller.show()
        #expect(controller.chat !== chat, "the next show did not start a new chat")
    }

    @Test func withTheFloatingChatOffStartAgentStillHandsTheChatToTheSidebar() async throws {
        let (rig, controller) = try Self.rig(floating: false)
        controller.show()
        let chat = try #require(controller.chat)
        _ = await chat.model.respond(to: Self.started("session-4"))

        #expect(rig.handedOff == ["session-4"])
        #expect(!rig.window.isVisible)
        #expect(controller.chat == nil)
        #expect(rig.window.held.isEmpty)
    }

    @Test func aHiddenFloatingChatSummonedOnAnotherScreenOpensWhereItWasLeftThere() {
        let laptop = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let monitor = CGRect(x: 1512, y: 0, width: 2560, height: 1415)
        let left = CGRect(x: 1000, y: 100, width: 400, height: 700)
        let composer = CGRect(x: 2452, y: 841, width: 680, height: 220)

        // Summoned on the screen it was left on: it stays put.
        #expect(FloatingChatFrames.summoned(onDisplay: "1", toDisplay: "1", saved: left, near: composer, in: laptop) == nil)
        // On the other screen: the frame it was left at there.
        let there = CGRect(x: 3600, y: 300, width: 420, height: 900)
        #expect(FloatingChatFrames.summoned(onDisplay: "1", toDisplay: "2", saved: there, near: composer, in: monitor) == there)
        // Never placed there: the default column, its top where the composer's would be.
        #expect(FloatingChatFrames.summoned(onDisplay: "1", toDisplay: "2", saved: nil, near: composer, in: monitor)
            == CGRect(x: 2572, y: 441, width: 440, height: 620))
    }

    @Test func theFloatingChatComesBackWhereItWasLeftOnEachScreen() throws {
        let suite = "floating-chat-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let laptop = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let composer = CGRect(x: 416, y: 488, width: 680, height: 220)

        // First time on a screen: the default column, its top where the composer's was.
        let first = FloatingChatFrames.placement(saved: FloatingChatFrames(defaults: defaults).frame(onDisplay: "1"), near: composer, in: laptop)
        #expect(first == CGRect(x: 536, y: 88, width: 440, height: 620))

        // Moved and resized there, then shown again (a new launch reads the same defaults).
        FloatingChatFrames(defaults: defaults).save(CGRect(x: 1100, y: 40, width: 380, height: 860), onDisplay: "1")
        let again = FloatingChatFrames(defaults: defaults)
        #expect(FloatingChatFrames.placement(saved: again.frame(onDisplay: "1"), near: composer, in: laptop)
            == CGRect(x: 1100, y: 40, width: 380, height: 860))
        // Another screen keeps its own.
        #expect(again.frame(onDisplay: "2") == nil)

        // A smaller screen under the same display id: the frame is kept on it.
        let small = CGRect(x: 0, y: 0, width: 1280, height: 720)
        #expect(FloatingChatFrames.placement(saved: again.frame(onDisplay: "1"), near: composer, in: small)
            == CGRect(x: 900, y: 0, width: 380, height: 720))
    }

    static func request(_ method: String, _ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": method, "params": params])
    }

    @Test func theFloatingChatsKeepOnTopAndCompactBarFollowThePageAndComeBackToIt() async throws {
        let (rig, controller) = try Self.rig(floating: true)
        controller.show()
        let chat = try #require(controller.chat)
        _ = await chat.model.respond(to: Self.started("session-5"))
        #expect(rig.pushed.last == AgentPaneFloatingState(holding: true, onTop: true, collapsed: false),
                "the page was not told it holds a running chat")

        let onTop = await chat.model.respond(to: Self.request("quick.setOnTop", ["onTop": false]))
        #expect(onTop["ok"] as? Bool == true)
        #expect(!rig.window.onTop, "the panel still floats over other windows")
        #expect(rig.pushed.last == AgentPaneFloatingState(holding: true, onTop: false, collapsed: false))

        _ = await chat.model.respond(to: Self.request("quick.setCollapsed", ["collapsed": true]))
        #expect(rig.window.collapsed, "the panel did not fold to its compact bar")
        #expect(rig.pushed.last == AgentPaneFloatingState(holding: true, onTop: false, collapsed: true))
        // A click elsewhere leaves the compact bar up, like the open chat.
        rig.window.loseKeys()
        #expect(rig.window.isVisible)

        _ = await chat.model.respond(to: Self.request("quick.setCollapsed", ["collapsed": false]))
        #expect(!rig.window.collapsed)
        #expect(rig.pushed.last == AgentPaneFloatingState(holding: true, onTop: false, collapsed: false))
    }

    @Test func aDraftIgnoresTheCompactBarAndMovingToATabOpensThePanelAgain() async throws {
        let (rig, controller) = try Self.rig(floating: true)
        controller.show()
        let draft = try #require(controller.chat)
        // Before the chat starts there is nothing to fold or keep up.
        _ = await draft.model.respond(to: Self.request("quick.setCollapsed", ["collapsed": true]))
        #expect(!rig.window.collapsed)
        #expect(rig.pushed.isEmpty)

        _ = await draft.model.respond(to: Self.started("session-6"))
        _ = await draft.model.respond(to: Self.request("quick.setOnTop", ["onTop": false]))
        _ = await draft.model.respond(to: Self.request("quick.setCollapsed", ["collapsed": true]))
        _ = await draft.model.respond(to: Self.request("quick.openInWindow", ["sessionId": "session-6"]))
        #expect(rig.opened == ["session-6"])
        #expect(!rig.window.collapsed, "the next composer would open folded")

        // The next floating chat opens unfolded and keeps the keep-on-top choice.
        controller.show()
        let next = try #require(controller.chat)
        _ = await next.model.respond(to: Self.started("session-7"))
        #expect(rig.pushed.last == AgentPaneFloatingState(holding: true, onTop: false, collapsed: false))
        #expect(!rig.window.onTop)
    }

    /// A chat tab's "..." menu Move to Floating Chat, as the page sends it: `pane.action {id: "floatingChat"}`.
    @Test func aChatTabsMoveToFloatingChatHandsItsSessionToTheApp() async throws {
        var moved: [String] = []
        let model = AgentPaneModel(host: NoHost(), sessionId: "session-8")
        model.header = AgentPaneHeaderHooks(run: { _, _ in }, tabState: { AgentPaneHeaderState() }, moveToFloatingChat: { session in
            moved.append(session)
            return true
        })
        let reply = await model.respond(to: Self.request("pane.action", ["id": "floatingChat"]))
        #expect(reply["ok"] as? Bool == true)
        #expect(moved == ["session-8"])

        // Nowhere to float it (the floating chat is off): the page hears it failed and the tab stays.
        model.header?.moveToFloatingChat = { _ in false }
        let refused = await model.respond(to: Self.request("pane.action", ["id": "floatingChat"]))
        #expect(refused["ok"] as? Bool == false)
    }

    @Test func aChatTabMovedToTheFloatingPanelKeepsItsSessionAndCanGoBackToATab() async throws {
        let (rig, controller) = try Self.rig(floating: true)
        #expect(controller.moveToFloatingChat(session: "session-9"))

        let chat = try #require(controller.chat)
        #expect(rig.made == ["session-9"], "the panel did not open the tab's own session")
        #expect(chat.model.sessionId == "session-9")
        #expect(controller.holdsChat)
        #expect(rig.window.isVisible)
        #expect(rig.window.held == [true])
        // The page reads the panel's state when it loads: it opens as the floating chat.
        let state = await chat.model.respond(to: Self.request("quick.floatingState", [:]))
        #expect((state["value"] as? [String: Any])?["holding"] as? Bool == true)

        // And back: the floating chat's Move to Tab opens the same session as a tab.
        _ = await chat.model.respond(to: Self.request("quick.openInWindow", ["sessionId": "session-9"]))
        #expect(rig.opened == ["session-9"])
        #expect(!controller.holdsChat)
    }

    @Test func movingAnotherTabToTheFloatingPanelSendsTheChatItHeldToATab() async throws {
        let (rig, controller) = try Self.rig(floating: true)
        controller.show()
        let first = try #require(controller.chat)
        _ = await first.model.respond(to: Self.started("session-10"))

        #expect(controller.moveToFloatingChat(session: "session-11"))
        #expect(rig.opened == ["session-10"], "the chat the panel held was dropped")
        #expect(controller.chat?.model.sessionId == "session-11")
        #expect(controller.holdsChat)
        #expect(rig.window.isVisible)
    }

    @Test func withTheFloatingChatOffATabStaysATab() throws {
        let (rig, controller) = try Self.rig(floating: false)
        #expect(!controller.moveToFloatingChat(session: "session-12"))
        #expect(controller.chat == nil)
        #expect(!rig.window.isVisible)
    }

    /// Start Agent's key (or Start Agent from Any App's, from another app) summons the floating chat to
    /// type in: a folded chat opens back out with the keys, and the key again puts it away.
    @Test func summoningAFoldedFloatingChatOpensItWithTheKeys() async throws {
        let (rig, controller) = try Self.rig(floating: true)
        controller.show()
        let chat = try #require(controller.chat)
        _ = await chat.model.respond(to: Self.started("session-13"))
        _ = await chat.model.respond(to: Self.request("quick.setCollapsed", ["collapsed": true]))
        rig.window.loseKeys()
        #expect(rig.window.isVisible)

        controller.toggle()
        #expect(rig.window.isKeyWindow)
        #expect(!rig.window.collapsed, "the summoned chat stayed folded")
        #expect(rig.pushed.last == AgentPaneFloatingState(holding: true, onTop: true, collapsed: false))

        controller.toggle()
        #expect(!rig.window.isVisible)
        // Hidden folded, it comes back open too.
        _ = await chat.model.respond(to: Self.request("quick.setCollapsed", ["collapsed": true]))
        controller.toggle()
        #expect(rig.window.isVisible)
        #expect(!rig.window.collapsed)
    }

    /// Include focused tab (⌘⇧I or the header's button): the page asks for what the user is looking at
    /// in cmux and attaches it to the next prompt only, as a chip the user sees and can remove.
    @Test func includeFocusedTabHandsThePageWhatTheUserIsLookingAt() async throws {
        let (rig, controller) = try Self.rig(floating: true)
        controller.show()
        let chat = try #require(controller.chat)
        _ = await chat.model.respond(to: Self.started("session-14"))

        rig.focused = AgentPaneQuickContext(name: "zsh · ~/src/app (selection)", text: "error: no such module 'Upload'")
        let reply = await chat.model.respond(to: Self.request("quick.context", [:]))
        let value = try #require(reply["value"] as? [String: Any])
        #expect(value["name"] as? String == "zsh · ~/src/app (selection)")
        #expect(value["text"] as? String == "error: no such module 'Upload'")

        // Nothing to include (an empty pane, no main window): the page hears there is none.
        rig.focused = nil
        let none = await chat.model.respond(to: Self.request("quick.context", [:]))
        #expect(none["ok"] as? Bool == true)
        #expect(none["value"] is NSNull)
    }
}


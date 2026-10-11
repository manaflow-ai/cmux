import AppKit
import CmuxNextAgentPane
import Foundation
import Testing
@testable import CmuxNextApp

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

        func present(_ content: NSView, focus: NSView?) {
            isVisible = true
            isKeyWindow = true
        }

        func dismiss() {
            isVisible = false
            isKeyWindow = false
        }

        func holdChat(_ holds: Bool) { held.append(holds) }

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
        var controller: QuickComposerController?
    }

    static func rig(floating: Bool) throws -> (Rig, QuickComposerController) {
        let page = FileManager.default.temporaryDirectory.appending(path: "floating-chat-\(UUID().uuidString)/index.html")
        try FileManager.default.createDirectory(at: page.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: page)
        let rig = Rig()
        let controller = QuickComposerController(
            makeChat: { AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(page)) },
            makeWindow: { rig.window },
            openInWindow: { session in
                rig.opened.append(session)
                return true
            },
            startInBackground: { start in
                rig.handedOff.append(start.sessionId)
                return true
            },
            floating: { floating })
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
}

import AppKit
import CmuxNextAgentPane
import Foundation
import Testing
@testable import CmuxNextApp

/// The floating chat across a quit (cx-xfc0c): the chat the panel held when
/// cmux quit comes back to it on the next summon, and is never dropped on
/// the way. Each relaunch is a new controller on the same user defaults.
@MainActor
struct FloatingChatRelaunchTests {
    /// A first launch whose panel holds `session` when cmux quits. Keep the
    /// returned rig alive to the end: it owns the defaults suite.
    static func quitHolding(_ session: String) async throws -> FloatingChatTests.Rig {
        let (rig, controller) = try FloatingChatTests.rig(floating: true)
        controller.show()
        let chat = try #require(controller.chat)
        _ = await chat.model.respond(to: FloatingChatTests.started(session))
        return rig
    }

    @Test func aChatTheFloatingChatHeldWhenCmuxQuitComesBackToItOnTheNextSummon() async throws {
        let rig = try await Self.quitHolding("session-quit")
        defer { withExtendedLifetime(rig) {} }

        let (relaunch, next) = try FloatingChatTests.rig(floating: true, suite: rig.suite)
        next.show()
        #expect(relaunch.made == ["session-quit"], "the next summon started an empty chat")
        #expect(next.chat?.model.sessionId == "session-quit")
        #expect(relaunch.window.held == [true], "the chat came back as a composer, not the floating chat")

        // Moved to a tab, the chat is no longer the panel's: the launch after that starts empty.
        _ = await next.chat?.model.respond(to: FloatingChatTests.request("quick.openInWindow", ["sessionId": "session-quit"]))
        let (third, last) = try FloatingChatTests.rig(floating: true, suite: rig.suite)
        last.show()
        #expect(third.made == [nil])
        #expect(third.window.held.isEmpty)
    }

    @Test func aHeldChatThatMovesToAnotherSessionComesBackOnThatSession() async throws {
        let rig = try await Self.quitHolding("session-a")
        defer { withExtendedLifetime(rig) {} }
        // A fork in the panel: the page persists the new session.
        let (_, first) = try FloatingChatTests.rig(floating: true, suite: rig.suite)
        first.show()
        _ = await first.chat?.model.respond(to: FloatingChatTests.request("chat.persistSession", ["sessionId": "session-fork"]))

        let (relaunch, next) = try FloatingChatTests.rig(floating: true, suite: rig.suite)
        next.show()
        #expect(relaunch.made == ["session-fork"])
    }

    @Test func aTabMovedToTheFloatingChatBeforeItsNextSummonSendsTheQuitChatToATab() async throws {
        let rig = try await Self.quitHolding("session-a")
        defer { withExtendedLifetime(rig) {} }

        let (relaunch, next) = try FloatingChatTests.rig(floating: true, suite: rig.suite)
        #expect(next.moveToFloatingChat(session: "session-b"))
        #expect(relaunch.opened == ["session-a"], "the chat held at quit was dropped")
        #expect(next.chat?.model.sessionId == "session-b")
    }

    @Test func turningTheFloatingChatOffKeepsTheQuitChatForWhenItIsBackOn() async throws {
        let rig = try await Self.quitHolding("session-a")
        defer { withExtendedLifetime(rig) {} }

        let (off, composer) = try FloatingChatTests.rig(floating: false, suite: rig.suite)
        composer.show()
        #expect(off.made == [nil])

        let (on, next) = try FloatingChatTests.rig(floating: true, suite: rig.suite)
        next.show()
        #expect(on.made == ["session-a"])
    }
}

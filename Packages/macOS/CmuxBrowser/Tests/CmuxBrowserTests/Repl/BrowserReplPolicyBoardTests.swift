import Foundation
import Testing

@testable import CmuxBrowser

/// A session's policy setter returns before WebKit compiles the policy's
/// content rules. The navigation checks must use the new policy at once,
/// and the navigations of the session's tabs must wait until the new rules
/// are on the tabs (or fail closed when WebKit refuses them).
@MainActor
@Suite("Browser REPL policy board")
struct BrowserReplPolicyBoardTests {
    private func prohibiting(_ pattern: String) throws -> BrowserReplDomainPolicy {
        var policy = BrowserReplDomainPolicy()
        policy.prohibited = [try BrowserReplDomainPattern.parse(pattern, title: "t")]
        return policy
    }

    /// Records each settle a waiter saw.
    private final class Settles {
        var states: [BrowserReplPolicyBoard.RuleState] = []
    }

    @Test("A published policy is what the checks read as soon as publish returns, from any thread")
    func publishIsSynchronous() async throws {
        let board = BrowserReplPolicyBoard()
        let policy = try prohibiting("evil.test")
        let box = SendableBox(policy)
        await Task.detached { board.publish(box.value, sessionID: "s") }.value
        #expect(board.policy(for: "s")?.blockReason("https://evil.test/") != nil)
        #expect(board.ruleState(for: "s") == .pending)
    }

    @Test("Navigations wait while the rules compile and go on once the latest rules are installed")
    func navigationsWaitForTheLatestRules() throws {
        let board = BrowserReplPolicyBoard()
        let first = board.publish(try prohibiting("a.test"), sessionID: "s")
        let latest = board.publish(try prohibiting("b.test"), sessionID: "s")
        let settles = Settles()
        board.whenRulesSettle(sessionID: "s") { settles.states.append($0) }
        #expect(settles.states.isEmpty, "a navigation went on before the rules were installed")
        board.rulesInstalled(sessionID: "s", generation: first)
        #expect(settles.states.isEmpty, "an older policy's rules released a navigation")
        #expect(board.ruleState(for: "s") == .pending)
        board.rulesInstalled(sessionID: "s", generation: latest)
        #expect(settles.states == [.installed])
        #expect(board.ruleState(for: "s") == .installed)
        board.whenRulesSettle(sessionID: "s") { settles.states.append($0) }
        #expect(settles.states == [.installed, .installed], "a navigation waited with the rules installed")
    }

    @Test("Rules WebKit refuses release the waiting navigations as failed, until a policy that compiles is installed")
    func refusedRulesFailClosed() throws {
        let board = BrowserReplPolicyBoard()
        let generation = board.publish(try prohibiting("a.test"), sessionID: "s")
        let settles = Settles()
        board.whenRulesSettle(sessionID: "s") { settles.states.append($0) }
        board.rulesFailed(sessionID: "s", generation: generation, reason: "bad rule")
        #expect(settles.states == [.failed("bad rule")])
        #expect(board.ruleState(for: "s") == .failed("bad rule"))
        let next = board.publish(try prohibiting("b.test"), sessionID: "s")
        #expect(board.ruleState(for: "s") == .pending)
        board.rulesInstalled(sessionID: "s", generation: next)
        #expect(board.ruleState(for: "s") == .installed)
    }

    @Test("A session that ends releases its waiting navigations and leaves no policy")
    func endingTheSessionReleases() throws {
        let board = BrowserReplPolicyBoard()
        board.publish(try prohibiting("a.test"), sessionID: "s")
        let settles = Settles()
        board.whenRulesSettle(sessionID: "s") { settles.states.append($0) }
        board.removeSession("s")
        #expect(settles.states == [.installed])
        #expect(board.policy(for: "s") == nil)
        #expect(board.ruleState(for: "s") == .installed)
    }

    @Test("An inactive policy publishes as no policy, and other sessions are not held")
    func sessionsAreSeparate() throws {
        let board = BrowserReplPolicyBoard()
        board.publish(BrowserReplDomainPolicy(), sessionID: "open")
        #expect(board.policy(for: "open") == nil)
        board.publish(try prohibiting("a.test"), sessionID: "s")
        let settles = Settles()
        board.whenRulesSettle(sessionID: "other") { settles.states.append($0) }
        #expect(settles.states == [.installed])
    }
}

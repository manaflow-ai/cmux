import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite struct ClaudeAccountAutoSwitchPolicyTests {
    private let home = "/Users/u"
    private let limit = "usage_limit: You've hit your limit"

    private var registry: ClaudeAccountRegistry {
        ClaudeAccountRegistry(
            declarations: [.init(name: "a", configDir: "~/.claude-a"), .init(name: "b", configDir: "~/.claude-b")],
            homeDirectory: home
        )
    }

    private func account(_ name: String) -> ClaudeAccount { registry.account(named: name)! }

    private func decide(
        _ detail: String?,
        current: ClaudeAccount,
        exhausted: Set<String> = [],
        trusted: (ClaudeAccount) -> Bool = { _ in true }
    ) -> ClaudeAccountAutoSwitchDecision {
        ClaudeAccountAutoSwitchPolicy.decide(
            failureDetail: detail, current: current, registry: registry,
            exhaustedKeys: exhausted, isTrusted: trusted, homeDirectory: home
        )
    }

    @Test func ignoresNonUsageLimit() {
        #expect(decide("rate_limit: slow down", current: account("a")) == .notUsageLimit)
        #expect(decide(nil, current: account("a")) == .notUsageLimit)
    }

    @Test func rotatesAfterCurrentAndWraps() {
        #expect(decide(limit, current: account("b")) == .switchTo(account("default"), sendContinue: true))
        #expect(decide(limit, current: account("default")) == .switchTo(account("a"), sendContinue: true))
    }

    @Test func skipsExhausted() {
        let exhausted: Set<String> = [account("a").exhaustionKey(homeDirectory: home)]
        #expect(decide(limit, current: account("default"), exhausted: exhausted) == .switchTo(account("b"), sendContinue: true))
    }

    @Test func prefersTrusted() {
        let result = decide(limit, current: account("default")) { $0.name == "b" }
        #expect(result == .switchTo(account("b"), sendContinue: true))
    }

    @Test func untrustedOnlyMeansNoContinue() {
        let result = decide(limit, current: account("default")) { _ in false }
        #expect(result == .switchTo(account("a"), sendContinue: false))
    }

    @Test func noAlternativeWhenAllExhausted() {
        let exhausted = Set(registry.accounts.map { $0.exhaustionKey(homeDirectory: home) })
        #expect(decide(limit, current: account("a"), exhausted: exhausted) == .noAlternative)
    }

    @Test func unregisteredCurrentStartsFromFirst() {
        let old = ClaudeAccount(name: "old", configDirectory: "/Users/u/.claude-old", isRegistered: false)
        #expect(decide(limit, current: old) == .switchTo(account("default"), sendContinue: true))
    }
}

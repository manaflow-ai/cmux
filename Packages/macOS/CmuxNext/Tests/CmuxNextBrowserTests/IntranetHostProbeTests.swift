@testable import CmuxNextBrowser
import Foundation
import Testing

/// A bare word that the company's DNS resolves (`wiki`, `go`) loads
/// `http://wiki/` with no setup, like Chrome's intranet redirect detection;
/// a resolver that answers every name, a slow answer, or Chrome's
/// IntranetRedirectBehavior policy 1 keeps it a search. No real DNS: the
/// lookup is a fake.
@MainActor @Suite struct IntranetHostProbeTests {
    /// Resolves `hosts` (or every name), counts its calls, and can hang
    /// until cancelled (a resolver slower than the probe's deadline).
    actor FakeLookup: HostLookup {
        let hosts: Set<String>
        let resolvesEverything: Bool
        let hangs: Bool
        private(set) var calls: [String] = []

        init(hosts: Set<String> = [], resolvesEverything: Bool = false, hangs: Bool = false) {
            self.hosts = hosts
            self.resolvesEverything = resolvesEverything
            self.hangs = hangs
        }

        func resolves(_ host: String) async -> Bool {
            calls.append(host)
            if hangs {
                // A fake resolver that never answers in time; the probe cancels it at its deadline.
                try? await Task.sleep(for: .seconds(600))
                return true
            }
            return resolvesEverything || hosts.contains(host)
        }
    }

    private func probe(_ lookup: FakeLookup, _ behavior: IntranetRedirectBehavior = .withInterceptionCheck,
                       timeout: Duration = .seconds(5)) -> IntranetHostProbe {
        IntranetHostProbe(lookup: lookup, behavior: behavior, timeout: timeout, randomLabel: { "zqxjkvbnmw" })
    }

    @Test func aBareWordThatResolvesIsAnIntranetHost() async {
        let lookup = FakeLookup(hosts: ["wiki"])
        #expect(await probe(lookup).resolves("Wiki"))
        #expect(await lookup.calls.contains("wiki"))
    }

    @Test func aWordThatDoesNotResolveStaysASearch() async {
        #expect(await probe(FakeLookup(hosts: ["wiki"])).resolves("recipes") == false)
    }

    @Test func aResolverThatAnswersEveryNameIsNotTrusted() async {
        let lookup = FakeLookup(resolvesEverything: true)
        #expect(await probe(lookup).resolves("wiki") == false)
        #expect(!(await lookup.calls.contains("wiki")), "the interception check answers first")
        #expect(await probe(FakeLookup(resolvesEverything: true), .withoutInterceptionCheck).resolves("wiki"))
    }

    @Test func policyOneNeverAsksDNS() async {
        let lookup = FakeLookup(hosts: ["wiki"])
        #expect(await probe(lookup, .disabled).resolves("wiki") == false)
        #expect(await lookup.calls.isEmpty)
    }

    @Test func aSlowAnswerFallsBackToSearch() async {
        let lookup = FakeLookup(hangs: true)
        #expect(await probe(lookup, .withoutInterceptionCheck, timeout: .milliseconds(20)).resolves("wiki") == false)
    }

    @Test func answersAreReused() async {
        let lookup = FakeLookup(hosts: ["wiki"])
        let probe = probe(lookup, .withoutInterceptionCheck)
        _ = await probe.resolves("wiki")
        _ = await probe.resolves("wiki")
        #expect(await lookup.calls == ["wiki"])
    }

    @Test(arguments: [("wiki", "wiki"), ("Go", "go"), ("jira-prod", "jira-prod")])
    func candidates(_ text: String, _ expected: String) {
        #expect(IntranetHostProbe.candidate(text) == expected)
    }

    @Test(arguments: ["go/gday", "two words", "1234", "x", "-go", "example.com", "wiki?", "日本"])
    func notCandidates(_ text: String) {
        #expect(IntranetHostProbe.candidate(text) == nil)
    }

    @Test(arguments: [(1, IntranetRedirectBehavior.disabled), (2, .withoutInterceptionCheck), (3, .withInterceptionCheck),
                      (0, .withInterceptionCheck)])
    func policyValues(_ value: Int, _ expected: IntranetRedirectBehavior) {
        #expect(IntranetRedirectBehavior(policyValue: value) == expected)
    }

    // MARK: The omnibar

    @Test func theOmnibarLoadsABareWordTheProbeFound() async throws {
        let engine = OmniboxSuggestionEngine()
        engine.intranetProbe = probe(FakeLookup(hosts: ["wiki"]))
        let rows = await engine.suggestions(for: "wiki")
        let first = try #require(rows.first)
        #expect(first.kind == .navigate)
        #expect(first.url.absoluteString == "http://wiki/")
        #expect(rows.dropFirst().first?.kind == .search, "the web search stays one pick away")
        #expect(engine.resolver.destination(for: "wiki") == .url(URL(string: "http://wiki/")!), "Enter loads it")
    }

    @Test func withoutAnAnswerABareWordSearches() async {
        let engine = OmniboxSuggestionEngine()
        engine.intranetProbe = probe(FakeLookup())
        let rows = await engine.suggestions(for: "wiki")
        #expect(rows.first?.kind == .search)
        guard case .search? = engine.resolver.destination(for: "wiki") else {
            Issue.record("wiki should search")
            return
        }
    }
}

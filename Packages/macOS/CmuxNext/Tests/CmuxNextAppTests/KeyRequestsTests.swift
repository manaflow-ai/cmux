@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// An agent's `cmux keys request NAME` waits for the person in Settings > Keys (design/settings-keys.md;
/// Leo, 2026-11-15: "letting agents safely write keys and store them or enter them jnto whatever").
/// The list is bounded and in memory; a second ask for a name replaces the first; a dropped asker
/// ends its request; the person's value goes only to `cmux keys put` on stdin, and only a stored
/// value answers the agent `stored`.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct KeyRequestsTests {
    @MainActor final class Ends {
        var outcomes: [String: KeyRequests.Outcome] = [:]
    }

    func add(_ requests: KeyRequests, _ name: String, ends: Ends, tag: String? = nil) -> String {
        let tag = tag ?? name
        return requests.add(name: name, purpose: "for \(name)", hosts: [], ttl: nil, requester: "CLAUDE_CODE_SESSION_ID=abc") {
            ends.outcomes[tag] = $0
        }
    }

    @Test func aNewAskForTheSameNameReplacesTheOldOneWhichEndsCancelled() {
        let requests = KeyRequests(), ends = Ends()
        let first = add(requests, "STRIPE_KEY", ends: ends, tag: "first")
        let second = add(requests, "STRIPE_KEY", ends: ends, tag: "second")
        #expect(requests.requests.map(\.id) == [second])
        #expect(ends.outcomes == ["first": .cancelled])
        #expect(requests.finish(first, .declined) == false, "an ended request ends once")
        #expect(requests.finish(second, .stored(name: "STRIPE_KEY")))
        #expect(ends.outcomes["second"] == .stored(name: "STRIPE_KEY"))
        #expect(requests.requests.isEmpty)
    }

    @Test func theListIsBoundedAndPushesOutTheOldest() {
        let requests = KeyRequests(), ends = Ends()
        for index in 0..<KeyRequests.limit { _ = add(requests, "KEY_\(index)", ends: ends) }
        #expect(requests.requests.count == KeyRequests.limit)
        #expect(ends.outcomes.isEmpty)
        _ = add(requests, "ONE_MORE", ends: ends)
        #expect(requests.requests.count == KeyRequests.limit)
        #expect(requests.requests.first?.name == "KEY_1")
        #expect(requests.requests.last?.name == "ONE_MORE")
        #expect(ends.outcomes == ["KEY_0": .cancelled])
    }

    @Test func aDroppedAskerEndsItsRequest() async {
        let requests = KeyRequests()
        let ask = KeyRequestParams(name: "NPM_TOKEN", purpose: "publish", requester: "user=you")
        let waiting = Task { @MainActor in await requests.ask(ask) }
        for _ in 0..<100 where requests.requests.isEmpty { await Task.yield() }
        #expect(requests.requests.map(\.name) == ["NPM_TOKEN"])
        waiting.cancel()
        #expect(await waiting.value == .cancelled)
        for _ in 0..<100 where !requests.requests.isEmpty { await Task.yield() }
        #expect(requests.requests.isEmpty)
    }

    @Test func anAskAnsweredByThePersonEndsStored() async throws {
        let requests = KeyRequests()
        let ask = KeyRequestParams(name: "NPM_TOKEN", purpose: "publish", requester: "user=you")
        @MainActor final class Added { var id: String? }
        let added = Added()
        let waiting = Task { @MainActor in await requests.ask(ask) { added.id = $0 } }
        for _ in 0..<100 where added.id == nil { await Task.yield() }
        let id = try #require(added.id)
        requests.finish(id, .declined)
        #expect(await waiting.value == .declined)
    }

    @Test func paramsAreChecked() throws {
        let ok = try KeyRequestParams(["name": "STRIPE_KEY", "purpose": " checkout tests ", "hosts": ["API.Stripe.com", "api.stripe.com", ""],
                                       "ttl": "90d", "requester": "CODEX_SESSION_ID=x"])
        #expect(ok == KeyRequestParams(name: "STRIPE_KEY", purpose: "checkout tests", hosts: ["api.stripe.com"], ttl: "90d", requester: "CODEX_SESSION_ID=x"))
        #expect(throws: (any Error).self) { try KeyRequestParams(["name": "lower", "purpose": "x"]) }
        #expect(throws: (any Error).self) { try KeyRequestParams(["name": "OK", "purpose": "  "]) }
        #expect(throws: (any Error).self) { try KeyRequestParams(["name": .string(String(repeating: "A", count: 81)), "purpose": "x"]) }
        #expect(KeyRequestNotices.actorLabel("CLAUDE_CODE_SESSION_ID=4f2a9c1e-77b0") == "Claude Code · 4f2a9c1e")
        #expect(KeyRequestNotices.actorLabel("user=you") == "you")
        #expect(KeyRequestNotices.actorLabel("unknown") == nil)
    }

    // MARK: The CLI

    /// Records each run; answers what `answer` returns.
    final class FakeCLI: @unchecked Sendable {
        var runs: [(arguments: [String], stdin: Data?)] = []
        var answer: ([String]) -> KeysCLI.Output = { _ in KeysCLI.Output(status: 0, stdout: Data("{}\n".utf8), stderr: Data()) }

        func cli() -> KeysCLI {
            var cli = KeysCLI(binary: URL(fileURLWithPath: "/fake/cmux"))
            cli.run = { [self] _, arguments, stdin, _ in
                runs.append((arguments, stdin))
                return answer(arguments)
            }
            return cli
        }
    }

    @Test func putSendsTheValueOnStdinOnly() async throws {
        let fake = FakeCLI()
        fake.answer = { _ in KeysCLI.Output(status: 0, stdout: Data(#"{"stored":{"id":"local-npm_token","name":"NPM_TOKEN"}}"#.utf8), stderr: Data()) }
        let answer = try await fake.cli().put(KeysCLI.Put(name: "NPM_TOKEN", purpose: "publish", hosts: ["registry.npmjs.org"], ttl: "30d",
                                                          askedBy: "CLAUDE_CODE_SESSION_ID=abc"), value: "the-value")
        #expect(answer["stored"]?["name"] == .string("NPM_TOKEN"))
        let run = try #require(fake.runs.first)
        #expect(run.arguments == ["keys", "put", "NPM_TOKEN", "--purpose", "publish", "--hosts", "registry.npmjs.org", "--ttl", "30d",
                                  "--replace", "--from-person", "--asked-by", "CLAUDE_CODE_SESSION_ID=abc", "--json"])
        #expect(!run.arguments.contains("the-value"))
        #expect(run.stdin == Data("the-value".utf8))
    }

    @Test func answersAreReadBareOrEnvelopedAndFailuresFromStderr() throws {
        let bare = try KeysCLI.answer(status: 0, stdout: Data(#"{"version":1,"keys":[]}"#.utf8), stderr: Data())
        #expect(bare["version"] as? Int == 1)
        let wrapped = try KeysCLI.answer(status: 0, stdout: Data("progress\n{\"ok\":true,\"result\":{\"keys\":[1]}}\n".utf8), stderr: Data())
        #expect((wrapped["keys"] as? [Int]) == [1])
        #expect(throws: KeysCLI.Failure(code: "keys.failed", message: "keychain locked")) {
            try KeysCLI.answer(status: 1, stdout: Data(), stderr: Data(#"{"code":"keys.failed","message":"cmux: keychain locked","details":{},"retryable":false}"#.utf8))
        }
        #expect(throws: KeysCLI.Failure(code: "keys.exists", message: "taken")) {
            try KeysCLI.answer(status: 0, stdout: Data(#"{"ok":false,"error":{"code":"keys.exists","message":"taken"}}"#.utf8), stderr: Data())
        }
    }

    // MARK: Settings > Keys

    @Test func storeEndsTheRequestOnlyAfterThePutSucceeded() async throws {
        let requests = KeyRequests(), ends = Ends(), fake = FakeCLI()
        let id = add(requests, "STRIPE_KEY", ends: ends)
        let page = SettingsKeys(requests: requests, cli: { fake.cli() })
        fake.answer = { _ in KeysCLI.Output(status: 1, stdout: Data(), stderr: Data(#"{"code":"keys.failed","message":"keychain locked"}"#.utf8)) }
        await #expect(throws: PageError.self) { try await page.answer(id, value: "typed") }
        #expect(requests.requests.map(\.id) == [id], "a refused store leaves the request waiting")
        #expect(ends.outcomes.isEmpty)
        fake.answer = { _ in KeysCLI.Output(status: 0, stdout: Data(#"{"stored":{"id":"local-stripe_key"}}"#.utf8), stderr: Data()) }
        let answer = try await page.answer(id, value: "typed")
        #expect(answer == .object(["stored": .bool(true), "name": .string("STRIPE_KEY")]))
        #expect(ends.outcomes["STRIPE_KEY"] == .stored(name: "STRIPE_KEY"))
        #expect(requests.requests.isEmpty)
        #expect(fake.runs.allSatisfy { $0.stdin == Data("typed".utf8) && !$0.arguments.contains("typed") })
        // The list names the request and the CLI's keys, never a value.
        _ = add(requests, "OTHER_KEY", ends: ends)
        fake.answer = { _ in KeysCLI.Output(status: 0, stdout: Data(#"{"version":1,"providers":[],"keys":[{"id":"local-stripe_key","name":"STRIPE_KEY","state":"live"}]}"#.utf8), stderr: Data()) }
        let list = await page.list()
        #expect(list["available"] == .bool(true))
        #expect(list["keys"]?.arrayValue?.count == 1)
        #expect(list["requests"]?.arrayValue?.first?["name"] == .string("OTHER_KEY"))
    }

    @Test func declineAnswersTheAgentDeclined() throws {
        let requests = KeyRequests(), ends = Ends()
        let id = add(requests, "STRIPE_KEY", ends: ends)
        let page = SettingsKeys(requests: requests, cli: { nil })
        _ = try page.decline(id)
        #expect(ends.outcomes["STRIPE_KEY"] == .declined)
        #expect(throws: PageError.self) { try page.decline(id) }
    }
}

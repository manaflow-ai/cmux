@testable import CmuxNextKeys
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
        let first = add(requests, "DEPLOY_KEY", ends: ends, tag: "first")
        let second = add(requests, "DEPLOY_KEY", ends: ends, tag: "second")
        #expect(requests.requests.map(\.id) == [second])
        #expect(ends.outcomes == ["first": .cancelled])
        #expect(requests.finish(first, .declined) == false, "an ended request ends once")
        #expect(requests.finish(second, .stored(name: "DEPLOY_KEY")))
        #expect(ends.outcomes["second"] == .stored(name: "DEPLOY_KEY"))
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

    @Test func aCancelledAskEndsItsRequest() async {
        let requests = KeyRequests()
        let ask = KeyRequestParams(name: "PUBLISH_TOKEN", purpose: "publish", requester: "user=you")
        let waiting = Task { await requests.ask(ask) }
        for _ in 0..<100 where requests.requests.isEmpty { await Task.yield() }
        #expect(requests.requests.map(\.name) == ["PUBLISH_TOKEN"])
        waiting.cancel()
        #expect(await waiting.value == .cancelled)
        for _ in 0..<100 where !requests.requests.isEmpty { await Task.yield() }
        #expect(requests.requests.isEmpty)
    }

    @Test func anAskerThatLeftEndsItsRequestEvenBeforeItIsAdded() async {
        let requests = KeyRequests()
        let ask = KeyRequestParams(name: "PUBLISH_TOKEN", purpose: "publish", requester: "user=you")
        let id = KeyRequests.newID()
        let waiting = Task { await requests.ask(ask, id: id) }
        for _ in 0..<100 where requests.requests.isEmpty { await Task.yield() }
        requests.abandon(id)
        #expect(await waiting.value == .cancelled)
        #expect(requests.requests.isEmpty)
        // The connection closed before the ask was added: it ends as soon as it is.
        let early = KeyRequests.newID()
        requests.abandon(early)
        #expect(await requests.ask(ask, id: early) == .cancelled)
        #expect(requests.requests.isEmpty)
    }

    @Test func anAskAnsweredByThePersonEndsWithTheirAnswer() async throws {
        let requests = KeyRequests()
        let ask = KeyRequestParams(name: "PUBLISH_TOKEN", purpose: "publish", requester: "user=you")
        let id = KeyRequests.newID()
        let waiting = Task { await requests.ask(ask, id: id) }
        for _ in 0..<100 where requests.requests.isEmpty { await Task.yield() }
        #expect(requests.finish(id, .declined))
        #expect(await waiting.value == .declined)
    }

    @Test func bannersFollowTheRequestsAndTheStreamCarriesOnlyARevision() async throws {
        let requests = KeyRequests()
        var posted: [String] = [], withdrawn: [String] = [], revisions: [Int] = []
        requests.onAdded = { posted.append($0.bannerTitle + " | " + $0.bannerBody) }
        requests.onEnded = { withdrawn.append($0) }
        let stop = requests.watch { revisions.append($0) }
        let first = requests.add(name: "DEPLOY_KEY", purpose: "staging deploys", hosts: [], ttl: nil, requester: "CLAUDE_CODE_SESSION_ID=4f2a9c1e-77b0") { _ in }
        let second = requests.add(name: "DEPLOY_KEY", purpose: "again", hosts: [], ttl: nil, requester: "user=you") { _ in }
        #expect(posted == ["Claude Code · 4f2a9c1e asks for a key | DEPLOY_KEY: staging deploys", "you asks for a key | DEPLOY_KEY: again"])
        #expect(withdrawn == [first])
        stop()
        requests.finish(second, .declined)
        #expect(withdrawn == [first, second])
        #expect(revisions == [1, 2], "the watch stopped")
        #expect(KeyRequests.isBanner(KeyRequests.bannerPrefix + second))
        // The page's stream sends the revision only.
        let page = SettingsKeys(requests: requests, cli: { nil })
        var events: [JSONValue] = []
        let subscription = try await page.subscribe(SettingsKeys.changedStream, filter: .object([:]), context: PageCallContext(page: "cmux.settings"),
                                                    onEvent: { events.append($0) })
        _ = requests.add(name: "PUBLISH_TOKEN", purpose: "publish", hosts: [], ttl: nil, requester: "user=you") { _ in }
        subscription.cancel()
        _ = requests.add(name: "OTHER_KEY", purpose: "x", hosts: [], ttl: nil, requester: "user=you") { _ in }
        #expect(events == [.object(["revision": .number(4)])])
    }

    @Test func paramsAreChecked() throws {
        let ok = try KeyRequestParams(["name": "DEPLOY_KEY", "purpose": " staging deploys ", "hosts": ["API.Example.com", "api.example.com", ""],
                                       "ttl": "90d", "requester": "CODEX_SESSION_ID=x"])
        #expect(ok == KeyRequestParams(name: "DEPLOY_KEY", purpose: "staging deploys", hosts: ["api.example.com"], ttl: "90d", requester: "CODEX_SESSION_ID=x"))
        #expect(throws: (any Error).self) { try KeyRequestParams(["name": "lower", "purpose": "x"]) }
        #expect(throws: (any Error).self) { try KeyRequestParams(["name": "OK", "purpose": "  "]) }
        #expect(throws: (any Error).self) { try KeyRequestParams(["name": .string(String(repeating: "A", count: 81)), "purpose": "x"]) }
        #expect(KeyRequests.actorLabel("CLAUDE_CODE_SESSION_ID=4f2a9c1e-77b0") == "Claude Code · 4f2a9c1e")
        #expect(KeyRequests.actorLabel("user=you") == "you")
        #expect(KeyRequests.actorLabel("unknown") == nil)
    }

    // MARK: The CLI

    /// Records each run; answers what `answer` returns.
    nonisolated final class FakeCLI: @unchecked Sendable {
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
        fake.answer = { _ in KeysCLI.Output(status: 0, stdout: Data(#"{"stored":{"id":"local-publish_token","name":"PUBLISH_TOKEN"}}"#.utf8), stderr: Data()) }
        let answer = try await fake.cli().put(KeysCLI.Put(name: "PUBLISH_TOKEN", purpose: "publish", hosts: ["registry.example.com"], ttl: "30d",
                                                          askedBy: "CLAUDE_CODE_SESSION_ID=abc"), value: "the-value")
        #expect(answer["stored"]?["name"] == .string("PUBLISH_TOKEN"))
        let run = try #require(fake.runs.first)
        #expect(run.arguments == ["keys", "put", "PUBLISH_TOKEN", "--purpose", "publish", "--hosts", "registry.example.com", "--ttl", "30d",
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
        let id = add(requests, "DEPLOY_KEY", ends: ends)
        let page = SettingsKeys(requests: requests, cli: { fake.cli() })
        fake.answer = { _ in KeysCLI.Output(status: 1, stdout: Data(), stderr: Data(#"{"code":"keys.failed","message":"keychain locked"}"#.utf8)) }
        await #expect(throws: PageError.self) { try await page.answer(id, value: "typed") }
        #expect(requests.requests.map(\.id) == [id], "a refused store leaves the request waiting")
        #expect(ends.outcomes.isEmpty)
        fake.answer = { _ in KeysCLI.Output(status: 0, stdout: Data(#"{"stored":{"id":"local-deploy_key"}}"#.utf8), stderr: Data()) }
        let answer = try await page.answer(id, value: "typed")
        #expect(answer == .object(["stored": .bool(true), "name": .string("DEPLOY_KEY")]))
        #expect(ends.outcomes["DEPLOY_KEY"] == .stored(name: "DEPLOY_KEY"))
        #expect(requests.requests.isEmpty)
        #expect(fake.runs.allSatisfy { $0.stdin == Data("typed".utf8) && !$0.arguments.contains("typed") })
        // The list names the request and the CLI's keys, never a value.
        _ = add(requests, "OTHER_KEY", ends: ends)
        fake.answer = { _ in KeysCLI.Output(status: 0, stdout: Data(#"{"version":1,"providers":[],"keys":[{"id":"local-deploy_key","name":"DEPLOY_KEY","state":"live"}]}"#.utf8), stderr: Data()) }
        let list = await page.list()
        #expect(list["available"] == .bool(true))
        #expect(list["keys"]?.arrayValue?.count == 1)
        #expect(list["requests"]?.arrayValue?.first?["name"] == .string("OTHER_KEY"))
    }

    @Test func declineAnswersTheAgentDeclined() throws {
        let requests = KeyRequests(), ends = Ends()
        let id = add(requests, "DEPLOY_KEY", ends: ends)
        let page = SettingsKeys(requests: requests, cli: { nil })
        _ = try page.decline(id)
        #expect(ends.outcomes["DEPLOY_KEY"] == .declined)
        #expect(throws: PageError.self) { try page.decline(id) }
    }
}

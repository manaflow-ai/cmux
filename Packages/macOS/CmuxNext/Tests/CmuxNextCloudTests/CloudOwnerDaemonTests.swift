import CMUXAuthCore
@testable import CmuxNextCloud
import Foundation
import Testing

/// The person's hand-off and fork-run calls are the cmux daemon's `cloud.owner.*` (one `cmux cloud api` request
/// on the child's stdin), not Swift HTTP; a fake child stands in for the bundled cmux.
@Suite struct CloudOwnerDaemonTests {
    nonisolated final class Seen: @unchecked Sendable {
        // @unchecked: `requests` is read and written only under `lock`.
        private let lock = NSLock()
        private var requests: [[String: Any]] = []
        func add(_ r: [String: Any]) { lock.withLock { requests.append(r) } }
        var all: [[String: Any]] { lock.withLock { requests } }
    }

    private func owner(_ seen: Seen, answer: @escaping @Sendable (String) -> String) -> CloudOwnerAPIClient {
        var owner = CloudOwnerAPIClient(baseURL: URL(string: "https://owner.standin.invalid") ?? URL(fileURLWithPath: "/"),
                                        accessToken: { "access" }, teamID: { "team_cmux" }, buildSpace: .nightly)
        owner.daemonCall = { input, _ in
            let request = (try JSONSerialization.jsonObject(with: input) as? [String: Any]) ?? [:]
            seen.add(request)
            return Data((answer(request["call"] as? String ?? "") + "\n").utf8)
        }
        return owner
    }

    static let turn = #"{"id":"ho_0123456789abcdef0123","sessionId":"s1","machine":"m1","turn":2,"state":"open","status":"running"}"#

    @Test func handOffCallsAreTheDaemonsOwnerOps() async throws {
        let seen = Seen()
        let owner = owner(seen) { call in
            switch call {
            case "owner.handoffs":
                #"{"ok":true,"body":[{"id":"ho_0123456789abcdef0123","sessionId":"s1","status":"running","createdAt":5}]}"#
            case "owner.handoff_begin_turn":
                #"{"ok":true,"body":{"refusal":"handoff.turn_running","id":"ho_0123456789abcdef0123","sessionId":"s1","machine":"m1","turn":2,"state":"open","status":"running"}}"#
            default:
                #"{"ok":true,"body":\#(Self.turn)}"#
            }
        }
        let list = try await owner.handoffs(pages: 99)
        #expect(list.map(\.id) == ["ho_0123456789abcdef0123"])
        let opened = try await owner.handoffOpen(session: "s1", machine: "m1")
        #expect(opened.turn == 2 && opened.refusal == nil)
        let begun = try await owner.handoffBeginTurn("ho_0123456789abcdef0123", after: -3)
        #expect(begun.refusal == "handoff.turn_running")

        let requests = seen.all
        #expect(requests.map { $0["call"] as? String } == ["owner.handoffs", "owner.handoff_open", "owner.handoff_begin_turn"])
        #expect(requests.allSatisfy { $0["auth"] as? String == "owner" && $0["credential"] as? String == "access" })
        #expect((requests[0]["args"] as? [String: Any])?["pages"] as? Int == 50)
        #expect((requests[1]["args"] as? [String: Any])?["session"] as? String == "s1")
        #expect((requests[2]["args"] as? [String: Any])?["after"] as? Int == 0)
    }

    @Test func theKeyedStartSendsTheKeyAsTheStdinTailNeverInTheRequest() async throws {
        nonisolated final class Input: @unchecked Sendable {
            // @unchecked: set once by the fake child, read after the call returns.
            var bytes = Data()
        }
        let input = Input()
        var owner = CloudOwnerAPIClient(baseURL: URL(string: "https://owner.standin.invalid") ?? URL(fileURLWithPath: "/"),
                                        accessToken: { "access" }, teamID: { "team_cmux" }, buildSpace: .nightly)
        owner.daemonCall = { bytes, _ in
            input.bytes = bytes
            return Data(#"{"ok":true,"body":{"personInstance":"run_1"}}"#.utf8) + Data("\n".utf8)
        }
        let line = Data(String(repeating: "ab", count: 32).utf8) + Data("\n".utf8)
        let instance = try await owner.acpmuxKeyedStart("vm_0123456789abcdefghij", keyLineLength: line.count) { stream in
            line.withUnsafeBytes { stream.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: line.count) == line.count }
        }
        #expect(instance == "run_1")
        let parts = input.bytes.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: false)
        let head = try #require(JSONSerialization.jsonObject(with: Data(parts[0])) as? [String: Any])
        #expect(head["call"] as? String == "owner.acpmux_keyed_start")
        #expect((head["args"] as? [String: Any])?["key_length"] as? Int == 65)
        #expect(!String(decoding: parts[0], as: UTF8.self).contains("abab"))
        #expect(Data(parts[1]) == line)
    }

    @Test func aDaemonFailureIsTheSameAPIError() async {
        let owner = owner(Seen()) { _ in #"{"ok":false,"error":{"kind":"http","status":404,"body":"{}"}}"# }
        await #expect(throws: CloudAPIError.self) { try await owner.handoffOpen(session: "s1", machine: "m1") }
        let notTurn = self.owner(Seen()) { _ in #"{"ok":true,"body":{"id":"nope"}}"# }
        await #expect(throws: CloudAPIError.self) { try await notTurn.handoffOpen(session: "s1", machine: "m1") }
    }

    static let page = "https://github.com/apps/cmux/installations/new?state=a.eyJleHAiOjQxMDI0NDQ4MDB9.b"

    /// The person's GitHub reads and Connect GitHub are the daemon's `cloud.owner.github_*`; their answers read as the
    /// routes' did (the status's raw body through the same parsers, a repository list's refusal as not connected).
    @Test func gitHubCallsAreTheDaemonsOwnerOps() async {
        let seen = Seen()
        let owner = owner(seen) { call in
            switch call {
            case "owner.github_app":
                #"{"ok":true,"body":{"state":"ready","status":200,"body":{"configured":true,"app_slug":"cmux","connection":{"status":"active","repos":["a/b"]}}}}"#
            case "owner.github_repos":
                #"{"ok":true,"body":{"repos":[{"full_name":"acme/web","private":false,"default_branch":"main","size_kb":12}],"truncated":false,"cursor":null}}"#
            case "owner.github_connect": #"{"ok":true,"body":{"authorize_url":"\#(Self.page)","connection":"conn_1"}}"#
            case "owner.github_list": #"{"ok":true,"body":{"pending":true}}"#
            default: #"{"ok":true,"body":{"status":200,"body":{"ok":true,"value":{}}}}"#
            }
        }
        let status = await owner.gitHubAppStatus(team: "team_a")
        #expect(status.app == .ready && status.reposScope == "selected")
        let repos = await owner.gitHubRepos(team: "team_a", query: "  web ")
        #expect(repos == .success(CloudGitHubRepos(repos: [.init(fullName: "acme/web", isPrivate: false, defaultBranch: "main", sizeKb: 12)], truncated: false)))
        #expect(await owner.gitHubConnect(key: "k", returnTo: "cmux://integration/complete") == .page(URL(string: Self.page)!))
        #expect(await owner.gitHubConnectPending() == true)
        let completion = CloudGitHubCompletion(url: URL(string: "cmux://integration/complete?state=a.b.c&code=g")!, scheme: "cmux")!
        #expect(await owner.gitHubComplete(completion) == .connected)

        let requests = seen.all
        #expect(requests.map { $0["call"] as? String } == ["owner.github_app", "owner.github_repos", "owner.github_connect", "owner.github_list", "owner.github_complete"])
        #expect((requests[0]["args"] as? [String: Any])?["raw"] as? Bool == true)
        #expect((requests[1]["args"] as? [String: Any])?["query"] as? String == "web")
        #expect((requests[2]["args"] as? [String: Any])?["returnTo"] as? String == "cmux://integration/complete")
        #expect((requests[4]["args"] as? [String: Any])?["params"] as? [String: String] == ["state": "a.b.c", "code": "g"])
        #expect((requests[4]["args"] as? [String: Any])?["idempotencyKey"] as? String == "complete:a.b.c")
    }

    @Test func gitHubRefusalsReadAsTheRoutesDid() async {
        let notConnected = owner(Seen()) { _ in #"{"ok":false,"error":{"kind":"http","status":404,"code":"github.not_connected"}}"# }
        #expect(await notConnected.gitHubRepos(team: "team_a", query: nil) == .failure(.notConnected))
        #expect(await notConnected.gitHubAppStatus(team: "team_a").app == .unknown)
        #expect(await notConnected.gitHubConnectPending() == nil)
        let reauth = owner(Seen()) { _ in #"{"ok":false,"error":{"kind":"http","status":409,"code":"needs_reauth"}}"# }
        #expect(await reauth.gitHubRepos(team: "team_a", query: nil) == .failure(.notConnected))
        let down = owner(Seen()) { _ in #"{"ok":false,"error":{"kind":"http","status":503}}"# }
        #expect(await down.gitHubRepos(team: "team_a", query: nil) == .failure(.unavailable))
        #expect(await down.gitHubConnect(key: "k") == .noAnswer)
        let elsewhere = owner(Seen()) { _ in #"{"ok":true,"body":{"authorize_url":"https://example.com/apps/cmux/installations/new","connection":"c"}}"# }
        #expect(await elsewhere.gitHubConnect(key: "k") == .refused)
        let unknown = owner(Seen()) { _ in #"{"ok":true,"body":{"state":"unknown"}}"# }
        #expect(await unknown.gitHubAppStatus(team: "team_a").app == .unknown)
        // A team that is not a `team_…` id never reaches the daemon.
        let seen = Seen()
        #expect(await owner(seen) { _ in "" }.gitHubAppStatus(team: "acme").app == .unknown)
        #expect(seen.all.isEmpty)
    }

    @Test func aCloneTokenAnswerIsOnlyAnInstallationToken() {
        #expect(CloudGitHubCloneToken.parse(Data(#"{"token":"ghs_abc_1"}"#.utf8)) == CloudGitHubCloneToken(token: "ghs_abc_1"))
        #expect(CloudGitHubCloneToken.parse(Data(#"{"token":"ghp_abc"}"#.utf8)) == nil)
        #expect(CloudGitHubCloneToken.parse(Data(#"{"token":"ghs_a b"}"#.utf8)) == nil)
        #expect(CloudGitHubCloneToken.parse(Data("[]".utf8)) == nil)
    }
}

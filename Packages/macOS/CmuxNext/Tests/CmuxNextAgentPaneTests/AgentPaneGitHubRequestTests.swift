import CmuxNextActions
import CmuxNextCloud
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The new chat folder picker's GitHub methods: what the page may send, what each answers, and the
/// `github:owner/name` folder a Cloud start takes.
@MainActor
struct AgentPaneGitHubRequestTests {
    @Test func decodesTheThreeMethodsAndRefusesOtherParams() {
        #expect(AgentPaneRequest(body: ["method": "github.status", "params": [String: Any]()]) == .gitHub(.status))
        #expect(AgentPaneRequest(body: ["method": "github.connect"]) == .gitHub(.connect(repo: nil)))
        // #55104: a Cloud start card's Connect names the repository its machine could not clone; nothing else passes.
        #expect(AgentPaneRequest(body: ["method": "github.connect", "params": ["repo": "manaflow-ai/cmuxterm-hq"]]) == .gitHub(.connect(repo: "manaflow-ai/cmuxterm-hq")))
        #expect(AgentPaneRequest(body: ["method": "github.connect", "params": ["repo": NSNull()]]) == .gitHub(.connect(repo: nil)))
        for bad: Any in ["https://github.com/acme/api", "acme", "acme/api/x", 4] {
            #expect(AgentPaneRequest(body: ["method": "github.connect", "params": ["repo": bad]]) == .unsupported("github.connect"), "\(bad)")
        }
        #expect(AgentPaneRequest(body: ["method": "github.repos.list", "params": ["query": "cm"]]) == .gitHub(.repos(query: "cm")))
        #expect(AgentPaneRequest(body: ["method": "github.repos.list", "params": ["query": NSNull()]]) == .gitHub(.repos(query: nil)))
        #expect(AgentPaneRequest(body: ["method": "github.repos.list"]) == .gitHub(.repos(query: nil)))
        #expect(AgentPaneRequest(body: ["method": "github.repos.list", "params": ["query": 4]]) == .unsupported("github.repos.list"))
        #expect(AgentPaneRequest(body: ["method": "github.repos.list", "params": ["query": String(repeating: "a", count: 1025)]]) == .unsupported("github.repos.list"))
        #expect(AgentPaneRequest(body: ["method": "github.nope"]) == .unsupported("github.nope"))
    }

    /// `github.repos.checkout`: an `owner/name`, a key, and only absolute folders the page knows for it.
    @Test func decodesCheckoutAndRefusesAnythingButARepositoryAndFolders() {
        let checkout = { (params: [String: Any]) in AgentPaneRequest(body: ["method": "github.repos.checkout", "params": params]) }
        #expect(checkout(["repo": "acme/api", "idempotency_key": "k1"]) == .gitHub(.checkout(repo: "acme/api", candidates: [], key: "k1")))
        #expect(checkout(["repo": "acme/api", "candidates": ["/Users/me/api"], "idempotency_key": "k1"])
            == .gitHub(.checkout(repo: "acme/api", candidates: ["/Users/me/api"], key: "k1")))
        for bad: [String: Any] in [
            ["repo": "acme/api"],
            ["repo": "https://github.com/acme/api", "idempotency_key": "k1"],
            ["repo": "../api", "idempotency_key": "k1"],
            ["repo": "acme/api", "candidates": ["relative/api"], "idempotency_key": "k1"],
            ["repo": "acme/api", "candidates": "/Users/me/api", "idempotency_key": "k1"],
        ] {
            #expect(checkout(bad) == .unsupported("github.repos.checkout"), "\(bad)")
        }
        #expect(AgentPaneRequest.gitHub(.checkout(repo: "acme/api", candidates: ["/Users/me/secret"], key: "k1")).description
            == "github.repos.checkout")
    }

    @Test func thePageHostServesThem() {
        for method in AgentPaneGitHubRequest.methods {
            #expect(AgentPageOps.method(for: AgentPageOps.namespace + method) == method)
        }
        #expect(AgentPaneRequest.gitHub(.repos(query: "secret")).description == "github.repos.list")
    }

    @MainActor final class Asked { var query: String?? }

    static func gitHub(status: CloudGitHubPicker.Status = .ready(reposScope: "all"), connect: AgentPaneGitHubConnect = .opened,
                       repos: Result<CloudGitHubRepos, CloudGitHubRepos.Failure> = .success(.init(repos: [], truncated: false)),
                       asked: Asked = Asked()) -> AgentPaneGitHub {
        AgentPaneGitHub(status: { status }, connect: { connect }, repos: { asked.query = .some($0); return repos })
    }

    @Test func statusAnswersStateAndScope() async {
        let ready = await AgentPaneGitHubRequest.status.reply(Self.gitHub(status: .ready(reposScope: "selected"))) { false }
        #expect((ready["value"] as? [String: Any])?["state"] as? String == "ready")
        #expect((ready["value"] as? [String: Any])?["repos_scope"] as? String == "selected")
        #expect((ready["value"] as? [String: Any])?["reason"] is NSNull)
        let notConnected = await AgentPaneGitHubRequest.status.reply(Self.gitHub(status: .notConnected)) { false }
        #expect((notConnected["value"] as? [String: Any])?["state"] as? String == "not_connected")
        #expect((notConnected["value"] as? [String: Any])?["reason"] is NSNull)
        let none = await AgentPaneGitHubRequest.status.reply(nil) { false }
        #expect((none["value"] as? [String: Any])?["state"] as? String == "unavailable")
        #expect((none["value"] as? [String: Any])?["repos_scope"] is NSNull)
        #expect((none["value"] as? [String: Any])?["reason"] as? String == "unreachable")
    }

    @Test func statusSaysWhyConnectIsNeededAgain() async {
        let cases: [(CloudGitHubPicker.Status, String, String)] = [
            (.needsReauth(detail: "the GitHub App was uninstalled"), "needs_reauth", "the GitHub App was uninstalled"),
            (.needsReauth(detail: nil), "needs_reauth", AgentPaneModel.gitHubReauthMessage),
            (.linking, "linking", AgentPaneModel.gitHubConnectPendingMessage),
            (.error, "error", AgentPaneModel.gitHubConnectionErrorMessage),
            (.linkRefused(reason: nil), "link_refused", AgentPaneModel.gitHubLinkExpiredMessage),
            (.linkRefused(reason: "Only an owner can connect GitHub."), "link_refused", "Only an owner can connect GitHub."),
        ]
        for (status, problem, message) in cases {
            let reply = await AgentPaneGitHubRequest.status.reply(Self.gitHub(status: status)) { false }
            let value = reply["value"] as? [String: Any]
            #expect(value?["state"] as? String == "not_connected")
            #expect(value?["problem"] as? String == problem)
            #expect(value?["message"] as? String == message)
        }
        let plain = await AgentPaneGitHubRequest.status.reply(Self.gitHub(status: .notConnected)) { false }
        #expect((plain["value"] as? [String: Any])?["problem"] is NSNull)
        #expect((plain["value"] as? [String: Any])?["message"] is NSNull)
    }

    /// Unavailable says why, so the picker can still offer Connect GitHub (sign in first, or not set up here).
    @Test(arguments: [(.signedOut, "signed_out"), (.notConfigured, "not_configured"), (.unreachable, "unreachable")] as [(CloudGitHubPicker.Unavailable, String)])
    func unavailableStatusSaysWhy(reason: CloudGitHubPicker.Unavailable, text: String) async {
        let reply = await AgentPaneGitHubRequest.status.reply(Self.gitHub(status: .unavailable(reason))) { false }
        let value = reply["value"] as? [String: Any]
        #expect(value?["state"] as? String == "unavailable")
        #expect(value?["repos_scope"] is NSNull)
        #expect(value?["reason"] as? String == text)
    }

    /// Connect GitHub where GitHub is unavailable answers why, with the words the person reads.
    @Test func connectWhileUnavailableSaysWhy() async {
        let cases: [(CloudGitHubPicker.Unavailable, String, String)] = [
            (.signedOut, "github.signed_out", AgentPaneModel.gitHubSignedOutMessage),
            (.notConfigured, "github.not_configured", AgentPaneModel.gitHubNotConfiguredMessage),
            (.unreachable, "github.unavailable", AgentPaneModel.gitHubUnavailableMessage),
        ]
        for (reason, code, message) in cases {
            let reply = await AgentPaneGitHubRequest.connect(repo: nil).reply(Self.gitHub(status: .unavailable(reason), connect: .unavailable(reason))) { true }
            #expect((reply["error"] as? [String: Any])?["code"] as? String == code)
            #expect((reply["error"] as? [String: Any])?["userMessage"] as? String == message)
        }
        let connected = await AgentPaneGitHubRequest.connect(repo: nil).reply(Self.gitHub(connect: .alreadyConnected)) { true }
        #expect((connected["value"] as? [String: Any])?["opened"] as? Bool == false)
        let none = await AgentPaneGitHubRequest.connect(repo: nil).reply(nil) { true }
        #expect((none["error"] as? [String: Any])?["code"] as? String == "github.unavailable")
    }

    @Test func connectNeedsTheClickAndSaysWhetherItOpened() async {
        let noClick = await AgentPaneGitHubRequest.connect(repo: nil).reply(Self.gitHub()) { false }
        #expect((noClick["error"] as? [String: Any])?["code"] as? String == AgentPaneTransportError.gestureRequired.rawValue)
        let opened = await AgentPaneGitHubRequest.connect(repo: nil).reply(Self.gitHub()) { true }
        #expect((opened["value"] as? [String: Any])?["opened"] as? Bool == true)
        let failed = await AgentPaneGitHubRequest.connect(repo: nil).reply(Self.gitHub(connect: .failed("Sign in to cmux to connect GitHub."))) { true }
        #expect((failed["error"] as? [String: Any])?["code"] as? String == "github.connect_failed")
        #expect((failed["error"] as? [String: Any])?["userMessage"] as? String == "Sign in to cmux to connect GitHub.")
    }

    @Test func reposListTheRowsAndMapNoInstallation() async {
        let asked = Asked()
        let listed = CloudGitHubRepos(repos: [.init(fullName: "acme/api", isPrivate: true, defaultBranch: "main"),
                                              .init(fullName: "acme/web", isPrivate: false, defaultBranch: nil)], truncated: true)
        let reply = await AgentPaneGitHubRequest.repos(query: "ac").reply(Self.gitHub(repos: .success(listed), asked: asked)) { false }
        #expect(asked.query == .some("ac"))
        let value = reply["value"] as? [String: Any]
        let rows = value?["repos"] as? [[String: Any]]
        #expect(rows?.map { $0["full_name"] as? String } == ["acme/api", "acme/web"])
        #expect(rows?.first?["private"] as? Bool == true)
        #expect(rows?.first?["default_branch"] as? String == "main")
        #expect(rows?.last?["default_branch"] is NSNull)
        #expect(value?["truncated"] as? Bool == true)

        let notConnected = await AgentPaneGitHubRequest.repos(query: nil).reply(Self.gitHub(repos: .failure(.notConnected))) { false }
        #expect((notConnected["error"] as? [String: Any])?["code"] as? String == "github.not_connected")
        let unavailable = await AgentPaneGitHubRequest.repos(query: nil).reply(Self.gitHub(repos: .failure(.unavailable))) { false }
        #expect((unavailable["error"] as? [String: Any])?["code"] as? String == "github.unavailable")
    }

    /// Settings > Accounts' Connect GitHub (`connectResult()`), as the picker and Set Up GitHub read it.
    @Test func theSharedConnectsResultSaysWhatHappened() {
        #expect(AgentPaneGitHubConnect(.success(["status": .string("pending"), "detail": .string("Finish connecting in your browser, then refresh.")])) == .opened)
        #expect(AgentPaneGitHubConnect(.success(["status": .string("connected"), "detail": .string("Connected")])) == .alreadyConnected)
        #expect(AgentPaneGitHubConnect(.success(["status": .string("needs-action"), "detail": .string("Sign in to cmux to connect GitHub.")]))
                == .failed("Sign in to cmux to connect GitHub."))
        #expect(AgentPaneGitHubConnect(.failure(ActionWorkFailure("GitHub could not be updated. Refresh to try again.")))
                == .failed("GitHub could not be updated. Refresh to try again."))
    }

    /// The picker's own Connect GitHub (in the team a Cloud start's machine is made in): only a page it answers opens.
    @Test func thePickersConnectOpensOnlyThePageItAnswers() {
        let page = URL(string: "https://github.com/apps/cmux/installations/new")!
        var opened: [URL] = []
        let open = AgentPaneGitHubConnect(.open(page)) { opened.append($0) }
        let connected = AgentPaneGitHubConnect(.connected) { opened.append($0) }
        let unavailable = AgentPaneGitHubConnect(.unavailable(.unreachable)) { opened.append($0) }
        let notConfigured = AgentPaneGitHubConnect(.unavailable(.notConfigured)) { opened.append($0) }
        let failed = AgentPaneGitHubConnect(.failed) { opened.append($0) }
        #expect(open == .opened)
        #expect(connected == .alreadyConnected)
        #expect(unavailable == .unavailable(.unreachable))
        #expect(notConfigured == .unavailable(.notConfigured))
        #expect(failed == .failed(""))
        #expect(opened == [page])
    }

    /// Signed out, the picker's Connect GitHub starts the cmux sign-in when it has one, else says to sign in first.
    @Test func signedOutConnectStartsTheSignIn() {
        var signIns = 0
        var opened: [URL] = []
        let started = AgentPaneGitHubConnect(.unavailable(.signedOut), open: { opened.append($0) }, signIn: { signIns += 1 })
        #expect(started == .opened)
        #expect(signIns == 1)
        let noSignIn = AgentPaneGitHubConnect(.unavailable(.signedOut)) { opened.append($0) }
        #expect(noSignIn == .unavailable(.signedOut))
        let notConfigured = AgentPaneGitHubConnect(.unavailable(.notConfigured), open: { opened.append($0) }, signIn: { signIns += 1 })
        #expect(notConfigured == .unavailable(.notConfigured))
        #expect(signIns == 1)
        #expect(opened.isEmpty)
    }

    @Test(arguments: [
        ("github:acme/api", "acme/api"),
        ("github:manaflow-ai/cmux.next_2", "manaflow-ai/cmux.next_2"),
        ("github:acme", nil),
        ("github:acme/api/extra", nil),
        ("github:acme/..", nil),
        ("github:ac me/api", nil),
        ("github:/api", nil),
        ("github:acme/", nil),
        ("/Users/me/api", nil),
        ("GitHub:acme/api", nil),
    ] as [(String, String?)])
    func aGitHubFolderNamesOneRepository(folder: String, repository: String?) {
        #expect(AgentPaneGitHubFolder.repository(folder) == repository)
    }
    @Test func cloneRequiresTheURLAndIdempotencyKey() {
        let url = "https://git.example.test/acme/api"
        #expect(AgentPaneRequest(body: ["method": "repo.clone", "params": ["url": url, "idempotency_key": "k1"]])
                == .gitHub(.cloneURL(url: url, key: "k1")))
        #expect(AgentPaneRequest(body: ["method": "repo.clone", "params": ["url": url]]) == .unsupported("repo.clone"))
    }
}

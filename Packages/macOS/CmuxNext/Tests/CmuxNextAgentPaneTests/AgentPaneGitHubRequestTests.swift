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
        #expect(AgentPaneRequest(body: ["method": "github.connect"]) == .gitHub(.connect))
        #expect(AgentPaneRequest(body: ["method": "github.repos.list", "params": ["query": "cm"]]) == .gitHub(.repos(query: "cm")))
        #expect(AgentPaneRequest(body: ["method": "github.repos.list", "params": ["query": NSNull()]]) == .gitHub(.repos(query: nil)))
        #expect(AgentPaneRequest(body: ["method": "github.repos.list"]) == .gitHub(.repos(query: nil)))
        #expect(AgentPaneRequest(body: ["method": "github.repos.list", "params": ["query": 4]]) == .unsupported("github.repos.list"))
        #expect(AgentPaneRequest(body: ["method": "github.repos.list", "params": ["query": String(repeating: "a", count: 1025)]]) == .unsupported("github.repos.list"))
        #expect(AgentPaneRequest(body: ["method": "github.nope"]) == .unsupported("github.nope"))
    }

    @Test func thePageHostServesThem() {
        for method in AgentPaneGitHubRequest.methods {
            #expect(AgentPageOps.method(for: AgentPageOps.namespace + method) == method)
        }
        #expect(AgentPaneRequest.gitHub(.repos(query: "secret")).description == "github.repos.list")
    }

    @MainActor final class Asked { var query: String?? }

    static func gitHub(status: (String, String?) = ("ready", "all"), connect: AgentPaneGitHubConnect = .opened,
                       repos: Result<CloudGitHubRepos, CloudGitHubRepos.Failure> = .success(.init(repos: [], truncated: false)),
                       asked: Asked = Asked()) -> AgentPaneGitHub {
        AgentPaneGitHub(status: { (state: status.0, reposScope: status.1) }, connect: { connect }, repos: { asked.query = .some($0); return repos })
    }

    @Test func statusAnswersStateAndScope() async {
        let ready = await AgentPaneGitHubRequest.status.reply(Self.gitHub(status: ("ready", "selected"))) { false }
        #expect((ready["value"] as? [String: Any])?["state"] as? String == "ready")
        #expect((ready["value"] as? [String: Any])?["repos_scope"] as? String == "selected")
        let none = await AgentPaneGitHubRequest.status.reply(nil) { false }
        #expect((none["value"] as? [String: Any])?["state"] as? String == "unavailable")
        #expect((none["value"] as? [String: Any])?["repos_scope"] is NSNull)
    }

    @Test func connectNeedsTheClickAndSaysWhetherItOpened() async {
        let noClick = await AgentPaneGitHubRequest.connect.reply(Self.gitHub()) { false }
        #expect((noClick["error"] as? [String: Any])?["code"] as? String == AgentPaneTransportError.gestureRequired.rawValue)
        let opened = await AgentPaneGitHubRequest.connect.reply(Self.gitHub()) { true }
        #expect((opened["value"] as? [String: Any])?["opened"] as? Bool == true)
        let failed = await AgentPaneGitHubRequest.connect.reply(Self.gitHub(connect: .failed("Sign in to cmux to connect GitHub."))) { true }
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
}

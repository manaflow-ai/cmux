@testable import CmuxNextCloud
import Foundation
import Testing

/// GitHub's return to the App's Setup URL (the console's `/integrations/callback`) for a connect this build started is
/// caught before the page loads and finished by the app (Leo, 2026-11-25: "you're already in the app. so it shouldnt say
/// shit"); an organization member's request is said, not refused as an expired link.
struct CloudGitHubSetupReturnTests {
    private static let api = URL(string: "https://api.cmux.dev")!

    private static func state(_ claims: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: claims)
        let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "h.\(payload).s"
    }

    private static let ours = state(["provider": "github", "team": "team_0123456789abcdef0123", "ret": "cmux-dev-x://integration/complete",
                                     "repo": "manaflow-ai/cmux"])

    @Test func theConsoleCallbackForThisBuildsConnectIsItsOwnCompletionLink() throws {
        let url = try #require(URL(string: "https://console.cmux.dev/integrations/callback?state=\(Self.ours)&code=abc&installation_id=42&setup_action=install&utm=x"))
        guard case .complete(let link)? = CloudGitHubCompletion.setupReturn(url, scheme: "cmux-dev-x", api: Self.api) else {
            Issue.record("not taken"); return
        }
        let completion = try #require(CloudGitHubCompletion(url: link, scheme: "cmux-dev-x"))
        #expect(completion.params == ["state": Self.ours, "code": "abc", "installation_id": "42", "setup_action": "install"])
        #expect(!link.absoluteString.contains("utm"), "only GitHub's params go on")
        let staging = try #require(URL(string: "https://console-staging.cmux.dev/integrations/callback/?state=\(Self.ours)&code=abc"))
        #expect(CloudGitHubCompletion.setupReturn(staging, scheme: "cmux-dev-x", api: Self.api) != nil)
    }

    @Test func anotherBuildsAnotherHostOrTheWebsConnectLoadsThePage() throws {
        let url = try #require(URL(string: "https://console.cmux.dev/integrations/callback?state=\(Self.ours)&code=abc"))
        #expect(CloudGitHubCompletion.setupReturn(url, scheme: "cmux", api: Self.api) == nil, "another build's return")
        let web = Self.state(["provider": "github", "ret": "https://console.cmux.dev/settings"])
        let webURL = try #require(URL(string: "https://console.cmux.dev/integrations/callback?state=\(web)&code=abc"))
        #expect(CloudGitHubCompletion.setupReturn(webURL, scheme: "cmux-dev-x", api: Self.api) == nil, "the web's own connect")
        let evil = try #require(URL(string: "https://console.cmux.dev.evil.com/integrations/callback?state=\(Self.ours)&code=abc"))
        #expect(CloudGitHubCompletion.setupReturn(evil, scheme: "cmux-dev-x", api: Self.api) == nil)
        let http = try #require(URL(string: "http://console.cmux.dev/integrations/callback?state=\(Self.ours)&code=abc"))
        #expect(CloudGitHubCompletion.setupReturn(http, scheme: "cmux-dev-x", api: Self.api) == nil)
        let expired = try #require(URL(string: "https://console.cmux.dev/integrations/callback?state=\(Self.ours)&error=connection_link_expired"))
        #expect(CloudGitHubCompletion.setupReturn(expired, scheme: "cmux-dev-x", api: Self.api) == nil, "only the page words it")
    }

    @Test func aCodelessUpdateGoesOnThroughTheAuthorizeRoute() throws {
        let url = try #require(URL(string: "https://console.cmux.dev/integrations/callback?state=\(Self.ours)&installation_id=42&setup_action=update"))
        guard case .authorize(let next)? = CloudGitHubCompletion.setupReturn(url, scheme: "cmux-dev-x", api: Self.api) else {
            Issue.record("no bounce"); return
        }
        let parts = try #require(URLComponents(url: next, resolvingAgainstBaseURL: false))
        #expect(parts.host == "api.cmux.dev" && parts.path == "/v1/integrations/github/authorize")
        #expect(parts.queryItems == [URLQueryItem(name: "state", value: Self.ours), URLQueryItem(name: "installation_id", value: "42")])
    }

    @Test func anOrganizationRequestIsSaidNotRefused() throws {
        let url = try #require(URL(string: "https://console.cmux.dev/integrations/callback?state=\(Self.ours)&code=abc&setup_action=request"))
        guard case .complete(let link)? = CloudGitHubCompletion.setupReturn(url, scheme: "cmux-dev-x", api: Self.api) else {
            Issue.record("not taken"); return
        }
        let completion = try #require(CloudGitHubCompletion(url: link, scheme: "cmux-dev-x"))
        #expect(completion.isOwnerRequest)
        #expect(completion.repoOwner == "manaflow-ai")
        let install = try #require(URL(string: "cmux-dev-x://integration/complete?state=\(Self.ours)&code=abc&installation_id=4&setup_action=install"))
        #expect(try #require(CloudGitHubCompletion(url: install, scheme: "cmux-dev-x")).isOwnerRequest == false)
    }

    @Test func aSaveOnAnInstallationsSettingsPageEndsTheSheet() throws {
        let saved = try #require(URL(string: "https://console.cmux.dev/integrations/callback?installation_id=42&setup_action=update"))
        #expect(CloudGitHubCompletion.isSavedOnGitHub(saved))
        let withState = try #require(URL(string: "https://console.cmux.dev/integrations/callback?state=\(Self.ours)&installation_id=42&setup_action=update"))
        #expect(!CloudGitHubCompletion.isSavedOnGitHub(withState))
        let elsewhere = try #require(URL(string: "https://example.com/integrations/callback?installation_id=42&setup_action=update"))
        #expect(!CloudGitHubCompletion.isSavedOnGitHub(elsewhere))
    }

    @MainActor @Test func theProgressFollowsTheConnectFromOpenToItsEnd() {
        let changes = CloudGitHubChanges()
        changes.openedGitHub()
        #expect(changes.phase == .onGitHub)
        changes.closedGitHub()
        #expect(changes.phase == .idle, "closing the sheet before finishing goes back")
        changes.openedGitHub()
        changes.finishing()
        changes.closedGitHub()
        #expect(changes.phase == .finishing, "a close after GitHub came back changes nothing")
        changes.record(.connected, reason: nil, account: "manaflow-ai")
        #expect(changes.phase == .connected(account: "manaflow-ai"))
        changes.recordRequested(owner: "acme")
        #expect(changes.phase == .requested(owner: "acme"))
        #expect(changes.refusal == nil)
        changes.record(.refused(message: nil), reason: nil)
        #expect(changes.phase == .idle)
        #expect(changes.count == 7)
    }

    @Test func theConnectedAccountIsReadFromTheReply() {
        let body = Data(#"{"ok":true,"value":{"id":"conn_1","account":{"key":"1","name":"manaflow-ai"}}}"#.utf8)
        #expect(CloudOwnerAPIClient.connectedAccount(body: body) == "manaflow-ai")
        #expect(CloudOwnerAPIClient.connectedAccount(body: Data(#"{"ok":true,"value":{}}"#.utf8)) == nil)
    }
}

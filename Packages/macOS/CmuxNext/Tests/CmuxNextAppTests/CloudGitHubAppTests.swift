@testable import CmuxNextCloud
import Foundation
import Testing

/// Set Up GitHub's check (`GET /v1/integrations/github/status`): which answers mean the cmux GitHub
/// App is ready for the team, and which send the machine to its own GitHub sign-in.
struct CloudGitHubAppTests {
    static func body(_ text: String) -> Data { Data(text.utf8) }

    @Test func anActiveConnectionOnAConfiguredAppIsReady() {
        let ready = Self.body(#"{"configured":true,"app_slug":"cmux","connection":{"status":"active","account_login":"acme"}}"#)
        #expect(CloudGitHubApp(status: 200, body: ready) == .ready)
    }

    @Test(arguments: [
        (200, #"{"configured":true,"app_slug":"cmux","connection":null}"#, CloudGitHubApp.notConnected),
        (200, #"{"configured":true,"app_slug":"cmux","allowed":false,"connection":{"status":"active"}}"#, .unknown),
        (200, #"{"configured":true,"app_slug":"cmux","allowed":true,"connection":{"status":"active"}}"#, .ready),
        (200, #"{"configured":true,"app_slug":"cmux","connection":{"status":"needs_reauth"}}"#, .needsReauth),
        (200, #"{"configured":true,"app_slug":"cmux","connection":{"status":"pending"}}"#, .linking),
        (200, #"{"configured":true,"app_slug":"cmux","connection":{"status":"error"}}"#, .error),
        (200, #"{"configured":true,"app_slug":"cmux","connection":{"status":"revoked"}}"#, .notConnected),
        (200, #"{"configured":true,"app_slug":"cmux","connection":{"status":"something_new"}}"#, .notConnected),
        (200, #"{"configured":false,"app_slug":null,"connection":null}"#, .notConfigured),
        (404, #"{"error":{"code":"integration.not_found","message":"no GitHub connection"}}"#, .notConnected),
        (503, #"{"error":{"code":"integration.unavailable","message":"GitHub App is not configured"}}"#, .unknown),
        (401, #"{"error":{"code":"auth.unauthenticated","message":"sign in"}}"#, .unknown),
        (200, #"{"connection":{"status":"active"}}"#, .unknown),
        (200, #"{"configured":true,"app_slug":"","connection":{"status":"active"}}"#, .unknown),
        (200, #"{"configured":true,"connection":{"status":"active"}}"#, .unknown),
        (200, #"{"configured":true,"app_slug":" \n","connection":{"status":"active"}}"#, .unknown),
        (200, "not json", .unknown),
        (502, "", .unknown),
    ])
    func everyOtherAnswerSaysWhy(status: Int, text: String, expected: CloudGitHubApp) {
        #expect(CloudGitHubApp(status: status, body: Self.body(text)) == expected)
    }

    @Test func aSuspendedInstallPointsAtItsSettingsAndAnUninstalledOneDoesNot() {
        let url = "https://github.com/settings/installations/42"
        let suspended = Self.body(#"{"configured":true,"app_slug":"cmux","connection":{"status":"needs_reauth","status_detail":"suspended","configure_url":"\#(url)"}}"#)
        #expect(CloudGitHubApp.configureURL(status: 200, body: suspended)?.absoluteString == url)
        #expect(CloudGitHubApp.reauthDetail(status: 200, body: suspended) == "suspended")
        let uninstalled = Self.body(#"{"configured":true,"app_slug":"cmux","connection":{"status":"needs_reauth","status_detail":"the GitHub App was uninstalled","configure_url":"\#(url)"}}"#)
        #expect(CloudGitHubApp.configureURL(status: 200, body: uninstalled) == nil)
        #expect(CloudGitHubApp.reauthDetail(status: 200, body: uninstalled) == "the GitHub App was uninstalled")
        // No reason, no page: Connect is the fix, and the words are the app's own.
        let bare = Self.body(#"{"configured":true,"app_slug":"cmux","connection":{"status":"needs_reauth"}}"#)
        #expect(CloudGitHubApp.configureURL(status: 200, body: bare) == nil)
        #expect(CloudGitHubApp.reauthDetail(status: 200, body: bare) == nil)
        // A reason on any other state is not shown, and a page that is not GitHub's installation settings never opens.
        let active = Self.body(#"{"configured":true,"app_slug":"cmux","connection":{"status":"active","status_detail":"x"}}"#)
        #expect(CloudGitHubApp.reauthDetail(status: 200, body: active) == nil)
        let elsewhere = Self.body(#"{"configured":true,"app_slug":"cmux","connection":{"status":"needs_reauth","configure_url":"https://evil.example/settings/installations/42"}}"#)
        #expect(CloudGitHubApp.configureURL(status: 200, body: elsewhere) == nil)
    }

    @MainActor @Test func eachConnectionStateGetsItsOwnPickerStatus() {
        #expect(CloudGitHubPicker.Status(.needsReauth, reposScope: nil, reauthDetail: "suspended") == .needsReauth(detail: "suspended"))
        #expect(CloudGitHubPicker.Status(.linking, reposScope: nil) == .linking)
        #expect(CloudGitHubPicker.Status(.error, reposScope: nil) == .error)
        for status: CloudGitHubPicker.Status in [.needsReauth(detail: nil), .linking, .error, .linkRefused(reason: nil)] {
            #expect(status.state == "not_connected", "the folder menu's three states stay three")
            #expect(status.problem != nil)
        }
        #expect(CloudGitHubPicker.Status.notConnected.problem == nil)
    }

    @MainActor @Test func aSuspendedInstallOpensItsSettingsFromConnectAndOthersAskForANewConnect() {
        let suspended = Self.body(#"{"configured":true,"app_slug":"cmux","connection":{"status":"needs_reauth","configure_url":"https://github.com/organizations/acme/settings/installations/7"}}"#)
        #expect(CloudGitHubPicker.connectFromStatus(status: 200, body: suspended) == .open(URL(string: "https://github.com/organizations/acme/settings/installations/7")!))
        for text in [#"{"configured":true,"app_slug":"cmux","connection":{"status":"needs_reauth"}}"#,
                     #"{"configured":true,"app_slug":"cmux","connection":{"status":"error"}}"#,
                     #"{"configured":true,"app_slug":"cmux","connection":{"status":"pending"}}"#] {
            #expect(CloudGitHubPicker.connectFromStatus(status: 200, body: Self.body(text)) == nil, "\(text)")
        }
    }

    @Test func onlyATeamIDReachesTheURL() {
        #expect(CloudGitHubApp.path(team: "team_01HZX9") == "/v1/integrations/github/status?team=team_01HZX9")
        for other in ["", "team_", "01HZX9", "team_a&b=c", "team_a/../x", "team_a b", "TEAM_a", "team_a\n"] {
            #expect(CloudGitHubApp.path(team: other) == nil, "\(other)")
        }
    }
}

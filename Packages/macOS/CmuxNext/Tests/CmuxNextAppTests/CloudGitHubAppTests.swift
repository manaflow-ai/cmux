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
        (200, #"{"configured":true,"app_slug":"cmux","connection":{"status":"needs_reauth"}}"#, .notConnected),
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

    @Test func onlyATeamIDReachesTheURL() {
        #expect(CloudGitHubApp.path(team: "team_01HZX9") == "/v1/integrations/github/status?team=team_01HZX9")
        for other in ["", "team_", "01HZX9", "team_a&b=c", "team_a/../x", "team_a b", "TEAM_a", "team_a\n"] {
            #expect(CloudGitHubApp.path(team: other) == nil, "\(other)")
        }
    }
}

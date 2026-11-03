import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

@MainActor struct SlackPageProviderTests {
    @Test func forwardsOnlySupportedMethodsAndReturnsConnectionJSON() async throws {
        var methods: [String] = []
        let provider = SlackPageProvider(request: { method in
            methods.append(method)
            return Data(#"{"connected":true,"teams":[{"slackTeamId":"T1","name":"Example","cmuxTeamId":"team_1"}]}"#.utf8)
        }, open: { _ in Issue.record("request must not open the browser") })
        let context = PageCallContext(page: PageDescriptor.settings.id)
        let reply = try await provider.call("cmux.settings.slack.request", params: ["method": "GET"], context: context)
        #expect(reply["connected"]?.boolValue == true)
        #expect(reply["teams"]?.arrayValue?.first?["name"]?.stringValue == "Example")
        for method in ["POST", "DELETE"] {
            _ = try await provider.call("cmux.settings.slack.request", params: ["method": .string(method)], context: context)
        }
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.settings.slack.request", params: ["method": "PATCH"], context: context)
        }
        #expect(methods == ["GET", "POST", "DELETE"])
    }

    @Test func opensHTTPSOnlyWithoutSendingCredentialsToBrowser() async throws {
        var opened: [URL] = []
        let provider = SlackPageProvider(request: { _ in
            Issue.record("browser handoff must not ask for credentials")
            return Data()
        }, open: { opened.append($0) })
        let context = PageCallContext(page: PageDescriptor.settings.id)
        let install = "https://platform.example/v1/slack/install?ticket=one-use"
        _ = try await provider.call("cmux.settings.slack.open", params: ["url": .string(install)], context: context)
        for invalid in ["http://slack.com/oauth/v2/authorize", "javascript:alert(1)", "https://user:secret@slack.com/"] {
            await #expect(throws: PageError.self) {
                _ = try await provider.call("cmux.settings.slack.open", params: ["url": .string(invalid)], context: context)
            }
        }
        #expect(opened.map(\.absoluteString) == [install])
    }
}

import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

@MainActor struct SlackPageProviderTests {
    @Test func forwardsOnlySupportedMethodsAndReturnsConnectionJSON() async throws {
        var methods: [String] = []
        let provider = SlackPageProvider(request: { method, _ in
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
        let provider = SlackPageProvider(request: { _, _ in
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

    @Test func createsAnOwnBotOnlyFromAConfigurationToken() async throws {
        var seen: [SlackOwnBot] = []
        let provider = SlackPageProvider(request: { method, bot in
            #expect(method == "POST")
            if let bot { seen.append(bot) }
            return Data(#"{"rid":"r1","appId":"A1","name":"Acme","installUrl":"https://platform.example/v1/slack/apps/r1/install?ticket=x"}"#.utf8)
        }, open: { _ in Issue.record("creating a bot must not open the browser itself") })
        let context = PageCallContext(page: PageDescriptor.settings.id)
        let token = "xoxe.xoxp-1-AAAAAAAAAAAA"
        let reply = try await provider.call("cmux.settings.slack.create_app", params: ["configToken": .string(token), "name": "Acme"], context: context)
        #expect(reply["installUrl"]?.stringValue?.hasPrefix("https://platform.example/") == true)
        #expect(seen.map(\.configToken) == [token])
        #expect(seen.map(\.name) == ["Acme"])
        for bad in ["", "xoxb-bot-token", "not a token"] {
            await #expect(throws: PageError.self) {
                _ = try await provider.call("cmux.settings.slack.create_app", params: ["configToken": .string(bad)], context: context)
            }
        }
        #expect(seen.count == 1)
    }

    @Test func connectedLinkOpensAccountsOnlyForTheSlackReturnLink() {
        var routes: [String] = []
        for (text, handled) in [("cmux://slack/connected", true), ("cmux-next://slack/connected?team=x", true), ("cmux://slack/other", false),
                                ("https://slack/connected", false), ("cmux://integration/complete", false)] {
            let url = URL(string: text)!
            #expect(SlackConnectedLink.handle(url, scheme: "cmux-next", show: { routes.append($0) }) == handled, "\(text)")
        }
        #expect(routes.count == 2)
        #expect(routes.allSatisfy { $0.hasPrefix("#/settings/accounts?slack=connected&open=") })
    }
}

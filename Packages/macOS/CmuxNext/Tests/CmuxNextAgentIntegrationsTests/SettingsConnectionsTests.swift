@testable import CmuxNextAgentIntegrations
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Settings > Integrations > Connections: the rows come from `cmux mcp-servers catalog --json`; Connect runs
/// `connect <name> --owner ... --return-to <scheme>://settings/integrations`, opens the https sign-in
/// page it answers in the system browser and reads the catalog again. A key goes to stdin only, and
/// nothing changes without the person's click.
@MainActor struct SettingsConnectionsTests {
    nonisolated static let cmux = URL(fileURLWithPath: "/Applications/cmux NEXT.app/Contents/Resources/bin/cmux")
    nonisolated static let click = PageCallContext(page: "cmux.settings", userGesture: true, gestureEvent: 1)
    nonisolated static let script = PageCallContext(page: "cmux.settings")

    nonisolated static let catalog = #"""
    {"ok":true,"available":true,"connected":1,"entries":[
      {"name":"linear","title":"Linear","state":"connected","connectionId":"mcs_1","keyField":false},
      {"name":"sentry","title":"Sentry","state":"connect","connectionId":null,"keyField":false},
      {"name":"exa","title":"Exa","state":"connect","connectionId":null,"keyField":true}
    ]}
    """#

    nonisolated final class Recorder: @unchecked Sendable {
        var calls: [[String]] = []
        var stdins: [Data?] = []
        var opened: [URL] = []
        var connectReply = #"{"ok":true,"authorizeUrl":"https://sentry.io/oauth/authorize?x=1"}"#
    }

    func make(_ recorder: Recorder) -> SettingsConnections {
        SettingsConnections(cli: { Self.cmux }, linkScheme: { "cmux-nightly" }, openInBrowser: { recorder.opened.append($0) }) { _, args, stdin in
            recorder.calls.append(args)
            recorder.stdins.append(stdin)
            let reply = args.contains("catalog") ? Self.catalog : recorder.connectReply
            return (0, Data(reply.utf8), Data())
        }
    }

    @Test func connectOpensTheSignInPageWithALinkBack() async throws {
        let recorder = Recorder()
        let page = make(recorder)
        await page.refresh()
        _ = try await page.call(SettingsConnections.runOp, params: ["action": "connect", "name": "sentry", "owner": "team", "team": "team_abc"], context: Self.click)
        #expect(recorder.calls[1] == ["mcp-servers", "connect", "sentry", "--owner", "team", "--return-to", "cmux-nightly://settings/integrations", "--team", "team_abc", "--json"])
        #expect(recorder.opened == [URL(string: "https://sentry.io/oauth/authorize?x=1")!])
        #expect(page.state["pending"]?.stringValue == "sentry")
    }

    @Test func aKeyGoesToStdinOnly() async throws {
        let recorder = Recorder()
        recorder.connectReply = #"{"ok":true,"connected":true}"#
        let page = make(recorder)
        await page.refresh()
        _ = try await page.call(SettingsConnections.runOp, params: ["action": "connect", "name": "exa", "key": " k-123 "], context: Self.click)
        #expect(recorder.calls[1].contains("--key-stdin"))
        #expect(!recorder.calls[1].contains { $0.contains("k-123") })
        #expect(recorder.stdins[1] == Data("k-123".utf8))
    }

    @Test func onlyAClickAndOnlyListedRowsRun() async throws {
        let recorder = Recorder()
        let page = make(recorder)
        await page.refresh()
        await #expect(throws: PageError.self) {
            _ = try await page.call(SettingsConnections.runOp, params: ["action": "remove", "id": "mcs_1"], context: Self.script)
        }
        await #expect(throws: PageError.self) {
            _ = try await page.call(SettingsConnections.runOp, params: ["action": "remove", "id": "mcs_other"], context: Self.click)
        }
        await #expect(throws: PageError.self) {
            _ = try await page.call(SettingsConnections.runOp, params: ["action": "connect", "name": "linear"], context: Self.click)
        }
        #expect(throws: PageError.self) {
            _ = try SettingsConnections.arguments(action: "connect", params: ["name": "sentry", "team": "--platform=x"],
                                                  catalog: page.state["catalog"] ?? .null, returnTo: "cmux://settings/connections")
        }
        _ = try await page.call(SettingsConnections.runOp, params: ["action": "remove", "id": "mcs_1"], context: Self.click)
        #expect(recorder.calls.contains(["mcp-servers", "remove", "mcs_1", "--json"]))
    }
}

@testable import CmuxNextAgentIntegrations
import Foundation
import Testing

/// A chat's Connect card (`connections.connect`): the catalog is read again, then the entry's state picks
/// the CLI words. Connect runs `connect NAME --owner me --return-to <the chat's link>` and opens the sign-in
/// page; Reconnect runs `reconnect ID`; connected runs nothing; a key, an unavailable server or an
/// unknown name runs nothing and answers the reason the person reads.
@MainActor struct SettingsConnectionsChatConnectTests {
    nonisolated static let cmux = URL(fileURLWithPath: "/Applications/cmux NEXT.app/Contents/Resources/bin/cmux")

    nonisolated static let catalog = #"""
    {"ok":true,"available":true,"connected":2,"entries":[
      {"name":"linear","title":"Linear","state":"connected","connectionId":"mcs_1","keyField":false},
      {"name":"sentry","title":"Sentry","state":"connect","connectionId":null,"keyField":false},
      {"name":"exa","title":"Exa","state":"connect","connectionId":null,"keyField":true},
      {"name":"notion","title":"Notion","state":"reconnect","connectionId":"mcs_2","keyField":false},
      {"name":"figma","title":"Figma","state":"unavailable","connectionId":null,"keyField":false,"unavailableReason":"not set up on this server"}
    ]}
    """#

    nonisolated final class Recorder: @unchecked Sendable {
        var calls: [[String]] = []
        var opened: [URL] = []
        var reply = #"{"ok":true,"authorizeUrl":"https://provider.example/oauth/authorize?x=1"}"#
    }

    func make(_ recorder: Recorder) -> SettingsConnections {
        SettingsConnections(cli: { Self.cmux }, linkScheme: { "cmux-nightly" }, openInBrowser: { recorder.opened.append($0) }) { _, args, _ in
            recorder.calls.append(args)
            return (0, Data((args.contains("catalog") ? Self.catalog : recorder.reply).utf8), Data())
        }
    }

    /// The CLI words each run sent, catalog reads left out.
    func actions(_ recorder: Recorder) -> [[String]] { recorder.calls.filter { !$0.contains("catalog") } }

    @Test func connectRunsWithTheChatsLinkAndOpensTheSignInPage() async {
        let recorder = Recorder()
        let page = make(recorder)
        #expect(await page.connectFromChat(name: "sentry", returnTo: "cmux-nightly://session/ses-01") == nil)
        #expect(recorder.calls.first == ["mcp-servers", "catalog", "--json"], "the catalog is read first")
        #expect(actions(recorder) == [["mcp-servers", "connect", "sentry", "--owner", "me", "--return-to", "cmux-nightly://session/ses-01", "--json"]])
        #expect(recorder.opened == [URL(string: "https://provider.example/oauth/authorize?x=1")!])
        #expect(page.state["pending"]?.stringValue == "sentry")
    }

    @Test func withoutAUsableChatLinkTheSignInReturnsToSettings() async {
        for link in [nil, "cmux://session/ses-01", "https://cmux.com/x", "cmux-nightly://session/a b", String(repeating: "a", count: 513)] as [String?] {
            let recorder = Recorder()
            #expect(await make(recorder).connectFromChat(name: "sentry", returnTo: link) == nil)
            #expect(actions(recorder) == [["mcp-servers", "connect", "sentry", "--owner", "me", "--return-to", "cmux-nightly://settings/integrations", "--json"]], "\(String(describing: link))")
        }
    }

    @Test func reconnectRunsOnTheListedConnection() async {
        let recorder = Recorder()
        #expect(await make(recorder).connectFromChat(name: "notion", returnTo: "cmux-nightly://session/ses-01") == nil)
        #expect(actions(recorder) == [["mcp-servers", "reconnect", "mcs_2", "--return-to", "cmux-nightly://session/ses-01", "--json"]])
    }

    @Test func aConnectedServiceRunsNothing() async {
        let recorder = Recorder()
        #expect(await make(recorder).connectFromChat(name: "linear", returnTo: nil) == nil)
        #expect(actions(recorder).isEmpty)
        #expect(recorder.opened.isEmpty)
    }

    @Test func aKeyAnUnavailableServerOrAnUnknownNameRunsNothingAndSaysWhy() async {
        let recorder = Recorder()
        let page = make(recorder)
        #expect(await page.connectFromChat(name: "exa", returnTo: nil) == "Exa needs a key: paste it in Settings > Integrations.")
        #expect(await page.connectFromChat(name: "figma", returnTo: nil) == "cmux cannot connect Figma: not set up on this server")
        #expect(await page.connectFromChat(name: "x", returnTo: nil) == "x is not in cmux's connections catalog.")
        #expect(await page.connectFromChat(name: "", returnTo: nil) != nil)
        #expect(actions(recorder).isEmpty, "a key never passes through a chat")
        #expect(recorder.opened.isEmpty)
    }

    @Test func theCLIsRefusalIsTheReason() async {
        let recorder = Recorder()
        recorder.reply = #"{"ok":false,"error":{"code":"auth.required","message":"Sign in to cmux first."}}"#
        #expect(await make(recorder).connectFromChat(name: "sentry", returnTo: nil) == "Sign in to cmux first.")
        #expect(recorder.opened.isEmpty)
    }
}

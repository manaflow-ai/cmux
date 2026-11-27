import CmuxNextActions
@testable import CmuxNextApp
import Foundation
import Testing

/// A cmux link clicked in rendered Markdown (a Markdown file page, Home, an agent chat) opens in
/// this app when it names a workspace, pane, tab or chat, in the plain `cmux` scheme the Chief
/// and its documents write or in this build's own scheme; nothing else is an app link.
struct CmuxAppLinksTests {
    private let ws = "ws_0123456789abcdef0123456789abcdef"
    private let scheme = "cmux-dev-mytag"

    private func link(_ text: String, chiefHost: String? = "chief:2e448bc2") -> DeepLink? {
        CmuxAppLinks.link(for: URL(string: text)!, linkScheme: scheme, chiefHost: chiefHost)
    }

    @Test func aWorkspaceLinkInTheChiefsSchemeOrThisBuildsOpensThatWorkspace() {
        #expect(link("cmux://workspace/\(ws)")?.target == .workspace(ws))
        #expect(link("\(scheme)://workspace/\(ws)")?.target == .workspace(ws))
        #expect(link("cmux://workspace/\(ws)")?.url(scheme: scheme)?.absoluteString == "\(scheme)://workspace/\(ws)")
    }

    /// An exit of `open` that runs no action says what took the link (category app.links, "app link" for hq's
    /// link_log; goal agent-shortcut-found).
    @Test func anOpenExitPastTheActionsNamesWhatTookTheLink() {
        let url = URL(string: "cmux://settings/models/add?focus=1")!
        #expect(DeepLink.linkLine(url, "showed a settings route", done: true) == "app link settings/models/add showed a settings route: done")
        #expect(DeepLink.linkLine(url, "is no app link", done: false) == "app link settings/models/add is no app link: refused")
    }

    @Test func chiefsBackgroundLinkRunsChangeBackground() {
        // Chief's first-launch welcome offers it; it is the palette's and the CLI's Change Background….
        #expect(DeepLink.settingsAction(for: URL(string: "cmux://settings/background")!, linkScheme: scheme)?.id == "appearance.changeBackground")
        #expect(DeepLink.settingsAction(for: URL(string: "\(scheme)://settings/background")!, linkScheme: scheme)?.id == "appearance.changeBackground")
        #expect(DeepLink.settingsAction(for: URL(string: "cmux://settings/other")!, linkScheme: scheme) == nil)
        #expect(DeepLink.settingsAction(for: URL(string: "https://settings/background")!, linkScheme: scheme) == nil)
        #expect(DeepLink.settingsRoute(for: URL(string: "cmux://settings/models/add")!, linkScheme: scheme) == "#/settings/models?focus=models.add")
        #expect(DeepLink.settingsRoute(for: URL(string: "\(scheme)://settings/models/add")!, linkScheme: scheme) == "#/settings/models?focus=models.add")
        #expect(DeepLink.settingsRoute(for: URL(string: "cmux://settings/models")!, linkScheme: scheme) == "#/settings/models")
        #expect(DeepLink.settingsRoute(for: URL(string: "\(scheme)://settings/integrations?connected=linear&id=mcs_1")!, linkScheme: scheme) == "#/settings/integrations")
        #expect(DeepLink.settingsRoute(for: URL(string: "\(scheme)://settings/connections")!, linkScheme: scheme) == "#/settings/integrations")
        #expect(DeepLink.settingsRoute(for: URL(string: "cmux://settings/cloud")!, linkScheme: scheme) == "#/settings/cloud")
        #expect(DeepLink.settingsRoute(for: URL(string: "cmux://settings/cloud/claude")!, linkScheme: scheme) == "#/settings/cloud?focus=cloud.claude")
        #expect(DeepLink.settingsRoute(for: URL(string: "cmux://settings/cloud/chatgpt")!, linkScheme: scheme) == "#/settings/cloud?focus=cloud.chatgpt")
        #expect(DeepLink.settingsRoute(for: URL(string: "\(scheme)://settings/cloud/api-key")!, linkScheme: scheme) == "#/settings/cloud?focus=cloud.apiKey")
        #expect(DeepLink.settingsRoute(for: URL(string: "cmux://settings/background")!, linkScheme: scheme) == nil)
        // ask-6bed134465: every setting and connection has a link that lands exactly on it.
        for path in ["connections/github", "github", "accounts/github"] {
            #expect(DeepLink.settingsRoute(for: URL(string: "\(scheme)://settings/\(path)")!, linkScheme: scheme)
                == "#/settings/accounts?focus=connection.github")
        }
        #expect(DeepLink.settingsRoute(for: URL(string: "cmux://settings/terminal.fontSize")!, linkScheme: scheme) == "#/settings/terminal.fontSize")
        #expect(DeepLink.settingsRoute(for: URL(string: "cmux://settings/accounts/machines")!, linkScheme: scheme) == "#/settings/accounts?focus=machines")
        #expect(DeepLink.settingsRoute(for: URL(string: "cmux://settings/connections/linear")!, linkScheme: scheme) == "#/settings/connections?focus=linear")
        #expect(DeepLink.settingsRoute(for: URL(string: "cmux://settings/nonsense")!, linkScheme: scheme) == "#/settings/nonsense")
        #expect(DeepLink.settingsRoute(for: URL(string: "cmux://settings")!, linkScheme: scheme) == "#/settings")
        #expect(DeepLink.settingsRoute(for: URL(string: "cmux://settings/start-agent-from-any-app")!, linkScheme: scheme) == nil)
        #expect(DeepLink.settingsRoute(for: URL(string: "https://settings/models/add")!, linkScheme: scheme) == nil)
    }

    @Test func theWelcomesStartAgentLinkTurnsTheSystemWideKeyOnAndNeverOff() throws {
        // Chief's first-launch welcome lists Start Agent from Any App with this link while its key is off.
        for text in ["cmux://settings/start-agent-from-any-app", "\(scheme)://settings/start-agent-from-any-app"] {
            let action = try #require(DeepLink.settingsAction(for: URL(string: text)!, linkScheme: scheme))
            #expect(action.id == "palette.toggleSetting")
            #expect(action.arguments == ["setting": .string("app.startAgentGlobalHotKey"), "on": .bool(true)])
        }
        #expect(DeepLink.settingsAction(for: URL(string: "https://settings/start-agent-from-any-app")!, linkScheme: scheme) == nil)
    }

    @Test func paneTabAndSessionLinksOpenToo() {
        #expect(link("cmux://pane/pane_0123456789abcdef0123456789abcdef")?.target == .pane("pane_0123456789abcdef0123456789abcdef"))
        #expect(link("cmux://tab/tab_0123456789abcdef0123456789abcdef")?.target == .tab("tab_0123456789abcdef0123456789abcdef"))
        #expect(link("cmux://session/01a12408-f0a2")?.target == .session("01a12408-f0a2", turn: nil))
    }

    /// A named Chief (`<home>/c/<id>`) writes its own home id, not the app's Chief host (#28877):
    /// its link is an app link too, and opening it checks the home (`ChiefSidebar.openSubagentLink`).
    /// A build with no Chief, or another machine's subagent, takes none.
    @Test func aChiefSubagentLinkOpensForAnyChiefHomeOfThisMac() {
        let text = "cmux://chief/2e448bc2/session/01a12408-f0a2"
        #expect(link(text)?.target == .chiefSession(home: "2e448bc2", session: "01a12408-f0a2"))
        #expect(link(text, chiefHost: "chief:69e026c6")?.target == .chiefSession(home: "2e448bc2", session: "01a12408-f0a2"))
        #expect(link(text, chiefHost: nil) == nil)
        #expect(link(text + "?machine=machine_0123456789abcdef0123456789abcdef") == nil)
    }

    @Test(arguments: [
        "javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "vbscript:x", "ssh://host/x",
        "https://cmux.dev/workspace/ws_0123456789abcdef0123456789abcdef",
        "cmux://workspace/1", "cmux://workspace/ws_short", "other-app://workspace/ws_0123456789abcdef0123456789abcdef",
        "cmux://auth-callback",
    ])
    func everythingElseIsNotAnAppLink(_ text: String) {
        #expect(link(text) == nil)
    }
}

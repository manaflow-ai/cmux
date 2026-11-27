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
        #expect(DeepLink.settingsRoute(for: URL(string: "cmux://settings/models/add")!, linkScheme: scheme)?.hasPrefix("#/settings/models?focus=models.add&open=") == true)
        #expect(DeepLink.settingsRoute(for: URL(string: "\(scheme)://settings/models/add")!, linkScheme: scheme)?.hasPrefix("#/settings/models?focus=models.add&open=") == true)
        #expect(DeepLink.settingsRoute(for: URL(string: "cmux://settings/models")!, linkScheme: scheme) == "#/settings/models")
        #expect(DeepLink.settingsRoute(for: URL(string: "\(scheme)://settings/integrations?connected=linear&id=mcs_1")!, linkScheme: scheme) == "#/settings/integrations")
        #expect(DeepLink.settingsRoute(for: URL(string: "\(scheme)://settings/connections")!, linkScheme: scheme) == "#/settings/integrations")
        #expect(DeepLink.settingsRoute(for: URL(string: "cmux://settings/cloud")!, linkScheme: scheme) == "#/settings/cloud")
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

    @Test func legacyCloudSetupLinksOpenCloudModels() throws {
        for (path, provider) in [("claude", "claude"), ("chatgpt", "chatgpt")] {
            let link = try #require(URL(string: "cmux://settings/cloud/\(path)"))
            let route = try #require(DeepLink.settingsRoute(for: link, linkScheme: scheme))
            let url = try #require(URLComponents(string: String(route.dropFirst())))
            #expect(url.path == "/settings/cloud")
            #expect(url.queryItems?.first { $0.name == "provider" }?.value == provider)
            #expect(url.queryItems?.first { $0.name == "open" }?.value.flatMap(UUID.init(uuidString:)) != nil)
        }
        let apiKey = try #require(URL(string: "\(scheme)://settings/cloud/api-key"))
        #expect(DeepLink.settingsRoute(for: apiKey, linkScheme: scheme)?.hasPrefix("#/settings/cloud?focus=cloudModels.add") == true)
    }

    @Test(arguments: ["/models", "/cloud", "/cloud/api-key", "/cloud/models", "/cloud/models/add"])
    func aProviderInASettingsLinkGoesDirectlyToCloudModels(path: String) throws {
        let link = try #require(URL(string: "cmux://settings\(path)?provider=openrouter"))
        let route = try #require(DeepLink.settingsRoute(for: link, linkScheme: scheme))
        let url = try #require(URLComponents(string: String(route.dropFirst())))
        #expect(url.path == "/settings/cloud")
        #expect(url.queryItems?.first { $0.name == "provider" }?.value == "openrouter")
        #expect(url.queryItems?.first { $0.name == "open" }?.value.flatMap(UUID.init(uuidString:)) != nil)
    }

    @Test func cloudSetupLinkPreservesTheHeldSendsScope() throws {
        let link = try #require(URL(string: "cmux://settings/cloud/claude?machine=vm-a&environment=env-b&recoverySession=chat-c&fromSend=1"))
        let route = try #require(DeepLink.settingsRoute(for: link, linkScheme: scheme))
        let components = try #require(URLComponents(string: String(route.dropFirst())))
        for (name, value) in [("provider", "claude"), ("machine", "vm-a"), ("environment", "env-b"),
                              ("recoverySession", "chat-c"), ("fromSend", "1")] {
            #expect(components.queryItems?.first { $0.name == name }?.value == value)
        }
    }

    @Test func modelAddLinksOpenAProviderInModelsAndCloudLinksReopen() throws {
        let add = try #require(URL(string: "cmux://settings/models/add?provider=chatgpt"))
        #expect(DeepLink.settingsRoute(for: add, linkScheme: scheme)?.hasPrefix("#/settings/models?focus=models.add.chatgpt&open=") == true)
        let cloud = try #require(URL(string: "cmux://settings/cloud/models"))
        let first = try #require(DeepLink.settingsRoute(for: cloud, linkScheme: scheme))
        let second = try #require(DeepLink.settingsRoute(for: cloud, linkScheme: scheme))
        #expect(first.hasPrefix("#/settings/cloud?focus=card.cloudModels&open="))
        #expect(first != second)
    }

    @Test func legacyCloudSetupFocusKeysStillResolveForCLIRequests() throws {
        for (focus, provider) in [("cloud.claude", "claude"), ("cloud.chatgpt", "chatgpt")] {
            let route = try #require(DeepLink.modelSettingsRoute(focus: focus))
            let url = try #require(URLComponents(string: String(route.dropFirst())))
            #expect(url.path == "/settings/cloud")
            #expect(url.queryItems?.first { $0.name == "provider" }?.value == provider)
        }
        #expect(DeepLink.modelSettingsRoute(focus: "cloud.apiKey")?.hasPrefix("#/settings/cloud?focus=cloudModels.add") == true)
        #expect(DeepLink.modelSettingsRoute(focus: "card.cloudModels")?.hasPrefix("#/settings/cloud?focus=card.cloudModels&open=") == true)
        #expect(DeepLink.modelSettingsRoute(focus: "cloud.newWorkspacesInCloud") == nil)
    }

    @Test func pickerLinksOpenCloudModelConnectionsWithTheSelectedFamily() throws {
        for family in ["claude", "codex", "gemini", "grok-build"] {
            let route = DeepLink.cloudModelConnectionsRoute(family: family)
            #expect(route.hasPrefix("#"))
            let components = try #require(URLComponents(string: String(route.dropFirst())))
            #expect(components.path == "/settings/cloud")
            #expect(components.queryItems?.first { $0.name == "open" }?.value.flatMap(UUID.init(uuidString:)) != nil)
            #expect(components.queryItems?.first { $0.name == "provider" }?.value == family)
            #expect(components.queryItems?.first { $0.name == "focus" }?.value == "card.cloudModels")
            #expect(route != DeepLink.cloudModelConnectionsRoute(family: family))
        }
    }

    @Test(arguments: ["claude-login", "codex-login"])
    func modelLinksFocusDetectedRowsInModels(focus: String) throws {
        let link = try #require(URL(string: "cmux://settings/models?focus=\(focus)"))
        let route = try #require(DeepLink.settingsRoute(for: link, linkScheme: scheme))
        let components = try #require(URLComponents(string: String(route.dropFirst())))
        #expect(components.path == "/settings/models")
        #expect(components.queryItems?.first { $0.name == "focus" }?.value == focus)
    }

    @Test func aHeldCloudSendOpensTheFamilyFormWithAFreshVisit() throws {
        let route = DeepLink.cloudModelConnectionsRoute(family: "claude", fromSend: true)
        let url = try #require(URLComponents(string: String(route.dropFirst())))
        #expect(url.path == "/settings/cloud")
        #expect(url.queryItems?.first { $0.name == "provider" }?.value == "claude")
        #expect(url.queryItems?.first { $0.name == "open" }?.value.flatMap(UUID.init(uuidString:)) != nil)
        #expect(url.queryItems?.first { $0.name == "fromSend" }?.value == "1")
        #expect(!DeepLink.cloudModelConnectionsRoute(family: "claude").contains("fromSend"))
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

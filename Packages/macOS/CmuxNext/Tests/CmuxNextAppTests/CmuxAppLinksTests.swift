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

    @Test func chiefsBackgroundLinkRunsChangeBackground() {
        // Chief's first-launch welcome offers it; it is the palette's and the CLI's Change Background….
        #expect(CmuxAppLinks.settingsAction(for: URL(string: "cmux://settings/background")!, linkScheme: scheme) == "appearance.changeBackground")
        #expect(CmuxAppLinks.settingsAction(for: URL(string: "\(scheme)://settings/background")!, linkScheme: scheme) == "appearance.changeBackground")
        #expect(CmuxAppLinks.settingsAction(for: URL(string: "cmux://settings/other")!, linkScheme: scheme) == nil)
        #expect(CmuxAppLinks.settingsAction(for: URL(string: "https://settings/background")!, linkScheme: scheme) == nil)
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

    /// A subagent's chip or `aN` link, a chat session link and an agent link open an agent's chat, never a workspace
    /// beside the Chief: none of them docks the Chief (cmux#37372). A workspace, pane or tab link may, when
    /// `home.chiefDock.openBeside` is on.
    @Test func onlyAWorkspacePaneOrTabLinkMayDockTheChief() {
        func docks(_ text: String) -> Bool {
            CmuxAppLinks.keepsChiefDocked(URL(string: text)!, linkScheme: scheme, chiefHost: "chief:2e448bc2")
        }
        #expect(!docks("cmux://chief/2e448bc2/session/01a12408-f0a2"), "a subagent chip docked the Chief")
        #expect(!docks("\(scheme)://chief/2e448bc2/session/01a12408-f0a2"))
        #expect(!docks("cmux://session/01a12408-f0a2"), "a moved subagent's chip docked the Chief")
        #expect(!docks("cmux://agent/claude/0b6e4c1e-1d2f-4a8b-9c3d-5e6f7a8b9c0d"))
        #expect(!docks("https://cmux.com/deeplink/agent?harness=claude&session=0b6e4c1e-1d2f-4a8b-9c3d-5e6f7a8b9c0d"))
        #expect(docks("cmux://workspace/\(ws)"))
        #expect(docks("cmux://pane/pane_0123456789abcdef0123456789abcdef"))
        #expect(docks("cmux://tab/tab_0123456789abcdef0123456789abcdef"))
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

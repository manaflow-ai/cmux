import CmuxNextActions
import Foundation
import MessagesLabHome
import Testing

/// Home draws cmux app links (a workspace, pane, tab, chat or Chief subagent) as links and hands a
/// click to the app; every other non-web scheme stays text.
struct HomeCmuxAppLinkTests {
    @Test(arguments: [
        "cmux://workspace/ws_0123456789abcdef0123456789abcdef",
        "cmux://pane/pane_0123456789abcdef0123456789abcdef",
        "cmux://tab/tab_0123456789abcdef0123456789abcdef",
        "cmux://session/01a12408-f0a2-79a0",
        "cmux://session/01a12408-f0a2-79a0#turn-7",
        "cmux://chief/2e448bc2/session/01a12408-f0a2",
        "cmux-dev-tag://workspace/ws_0123456789abcdef0123456789abcdef",
        "cmux://workspace/ws_0123456789abcdef0123456789abcdef?machine=machine_0123456789abcdef0123456789abcdef",
        "cmux://settings/background",
        "cmux://settings/start-agent-from-any-app",
    ])
    func appLinks(_ text: String) {
        #expect(URL(string: text)!.isCmuxAppLink)
    }

    @Test(arguments: [
        "javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "vbscript:x", "ssh://host/x",
        "cmux://workspace/ws_short", "cmux://workspace/ws_0123456789ABCDEF0123456789ABCDEF",
        "cmux://workspace/ws_0123456789abcdef0123456789abcdef/extra", "cmux://u:p@workspace/ws_0123456789abcdef0123456789abcdef",
        "cmux://workspace/ws_0123456789abcdef0123456789abcdef?x=1", "cmux://auth-callback", "cmuxx://workspace/ws_0123456789abcdef0123456789abcdef",
        "https://cmux.dev/",
        "cmux://settings/other", "cmux://settings/background#x",
    ])
    func notAppLinks(_ text: String) {
        #expect(!URL(string: text)!.isCmuxAppLink)
    }

    /// Every settings link the app runs is one Home draws, and Home draws no other: a route added to
    /// DeepLink.settingsRoutes alone would show as plain text, as the welcome's Start Agent from Any App
    /// link did (cmux#42861, nightly 4359280404201).
    @Test func everySettingsRouteIsALinkHomeDraws() {
        #expect(Set(DeepLink.settingsRoutes.keys) == URL.homeSettingsLinkPaths)
        for path in DeepLink.settingsRoutes.keys {
            let url = URL(string: "cmux://settings\(path)")!
            #expect(url.isCmuxAppLink, "\(path)")
            #expect(DeepLink.settingsAction(for: url, linkScheme: "cmux-dev-x") != nil, "\(path)")
        }
    }
}

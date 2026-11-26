import CmuxNextBrowserTabs
import Foundation
import Testing

/// Which tab a sign-in's end closes (``SignInPageTab``): only the one page it opened, and only while
/// that tab is still on the provider's site.
struct SignInPageTabTests {
    private let device = URL(string: "https://github.com/login/device")!
    private func u(_ s: String?) -> URL? { s.flatMap(URL.init(string:)) }

    @Test func theOneTabStillOnTheProvidersHostCloses() {
        #expect(SignInPageTab.toClose([(id: "a", shown: [u("https://github.com/login/device/confirmation")])], of: device) == "a")
        #expect(SignInPageTab.toClose([(id: "a", shown: [u("https://GitHub.com/login")]), (id: "b", shown: [u("https://example.com/")])], of: device) == "a")
    }

    @Test func aTabThePersonTookElsewhereStays() {
        #expect(SignInPageTab.toClose([(id: "a", shown: [u("https://news.example.com/"), u("https://github.com/login/device")])], of: device) == nil)
        #expect(SignInPageTab.toClose([(id: "a", shown: [u("https://gist.github.com/")])], of: device) == nil)
    }

    @Test func twoTabsOnTheHostBothStay() {
        #expect(SignInPageTab.toClose([(id: "a", shown: [u("https://github.com/login/device")]), (id: "b", shown: [u("https://github.com/")])], of: device) == nil)
        #expect(SignInPageTab.toClose([(id: String, shown: [URL?])](), of: device) == nil)
    }

    /// A provider whose page moves between its own hosts (the daemon's `pageHosts`) still closes; any other host stays.
    @Test func aTabOnOneOfTheSignInsOwnHostsCloses() {
        let claude = URL(string: "https://claude.com/cai/oauth/authorize?code=true")!, hosts = ["claude.com", "Claude.AI", "platform.claude.com"]
        #expect(SignInPageTab.toClose([(id: "a", shown: [u("https://claude.ai/login")])], of: claude) == nil)
        #expect(SignInPageTab.toClose([(id: "a", shown: [u("https://claude.ai/login")])], of: claude, hosts: hosts) == "a")
        #expect(SignInPageTab.toClose([(id: "a", shown: [u("https://claude.ai.example.com/login")])], of: claude, hosts: hosts) == nil)
        #expect(SignInPageTab.toClose([(id: "a", shown: [u("https://claude.ai/login")]), (id: "b", shown: [u("https://platform.claude.com/x")])], of: claude, hosts: hosts) == nil)
    }

    /// A page that never loaded shows the engine's error page: the daemon's record still names the provider.
    @Test func aPageThatNeverLoadedCountsByItsRecord() {
        #expect(SignInPageTab.toClose([(id: "a", shown: [u("chrome-error://chromewebdata/"), u("https://github.com/login/device")])], of: device) == "a")
        #expect(SignInPageTab.toClose([(id: "a", shown: [nil, nil])], of: device) == nil)
    }
}

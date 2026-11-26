@testable import CmuxNextBrowser
import Foundation
import Testing

@MainActor
struct BrowserExternalAppConsentTests {
    @Test func firstClickAndRememberedConsent() throws {
        let suite = "BrowserExternalAppConsentTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let apps = BrowserExternalApps(defaults: defaults)
        let site = "https://example.test"

        for scheme in ["slack", "zoommtg", "zoom", "mailto", "tel", "vscode", "custom"] {
            #expect(!apps.canOpenWithoutPrompt(scheme, for: site, engine: .cef, userGesture: true))
        }
        #expect(apps.canOpenWithoutPrompt("slack", for: site, engine: .webkit, userGesture: true))
        #expect(!apps.canOpenWithoutPrompt("custom", for: site, engine: .webkit, userGesture: true))

        defaults.set([site: ["slack"]], forKey: "CmuxNextBrowser.externalSchemes")
        #expect(apps.canOpenWithoutPrompt("slack", for: site, engine: .cef, userGesture: true))
        #expect(!apps.canOpenWithoutPrompt("slack", for: site, engine: .cef, userGesture: false))
        #expect(!apps.canOpenWithoutPrompt("slack", for: "https://elsewhere.test", engine: .cef, userGesture: true))
        #expect(!apps.canOpenWithoutPrompt("mailto", for: site, engine: .cef, userGesture: true))
    }

    @Test func ownSchemesComeFromTheInfoPlist() {
        let info: [String: Any] = ["CFBundleURLTypes": [
            ["CFBundleURLSchemes": ["cmux-nightly"]],
            ["CFBundleURLSchemes": ["CMUX-DEV-tag", "ssh"]],
            ["CFBundleURLName": "no schemes"],
        ]]
        #expect(BrowserExternalApps.schemes(in: info) == ["cmux-nightly", "cmux-dev-tag", "ssh"])
        #expect(BrowserExternalApps.schemes(in: nil).isEmpty)
    }

    /// Leo 2026-11-25: a GitHub or sign-in return inside a cmux tab "should already know" it is
    /// in cmux: no "open cmux" prompt, the app's own route, the flow's tab closes.
    @Test func ownHandoffOpensInTheAppWithoutAPromptAndClosesTheFlowTab() throws {
        let (apps, cleanup) = try Self.apps()
        defer { cleanup() }
        var routed: [URL] = [], asked = 0, closed = 0
        apps.openOwnURL = { routed.append($0) }
        apps.isOwnHandoff = { $0.host == "integration" }
        apps.closesHandoffTab = { $0?.host == "github.com" }
        let back = try #require(URL(string: "cmux-nightly://integration/complete?state=a.b.c&installation_id=1"))
        let install = URL(string: "https://github.com/apps/cmux/installations/new")

        apps.open(back, from: install, userGesture: false, firstPage: install, close: { closed += 1 }) { _, _, _ in asked += 1 }
        #expect(routed == [back] && asked == 0 && closed == 1)

        // A tab the person was already using (not opened for the flow) stays open.
        apps.open(back, from: install, userGesture: false, firstPage: URL(string: "https://news.example"), close: { closed += 1 }) { _, _, _ in asked += 1 }
        #expect(routed == [back, back] && asked == 0 && closed == 1)
    }

    /// Settings > Connections opens a vendor's authorize page in a cmux tab; its return to
    /// `<scheme>://settings/integrations` goes to the app with no prompt and that tab closes. The tab
    /// is the one the app opened (its first requested address, before any redirect), not a URL guess.
    @Test func aFlowTabTheAppOpenedHandsItsReturnBackAndCloses() throws {
        let (apps, cleanup) = try Self.apps()
        defer { cleanup() }
        var routed: [URL] = [], asked = 0, closed = 0
        apps.openOwnURL = { routed.append($0) }
        apps.isOwnHandoff = { _ in false }
        apps.closesHandoffTab = { _ in false }
        apps.isFlowReturn = { $0.host == "settings" }
        let back = try #require(URL(string: "cmux-nightly://settings/integrations"))
        let connect = try #require(URL(string: "https://api.cmux.dev/v1/mcp-servers/oauth/start?id=linear"))
        let vendor = URL(string: "https://linear.app/oauth/consent")

        // Not opened for a flow: the settings link asks, as any own link does.
        apps.open(back, from: vendor, userGesture: false, firstPage: vendor, requestedPage: connect, close: { closed += 1 }) { _, _, _ in asked += 1 }
        #expect(routed.isEmpty && asked == 1 && closed == 0)

        apps.noteFlowPage(connect)
        apps.open(back, from: vendor, userGesture: false, firstPage: vendor, requestedPage: connect, close: { closed += 1 }) { _, _, _ in asked += 1 }
        #expect(routed == [back] && asked == 1 && closed == 1)

        // The flow ended: a second return from that address is not a flow's any more.
        apps.open(back, from: vendor, userGesture: false, firstPage: vendor, requestedPage: connect, close: { closed += 1 }) { _, _, _ in asked += 1 }
        #expect(routed == [back] && asked == 2 && closed == 1)
    }

    /// The cmux sign-in opened in a cmux tab: its `auth-callback` (an own handoff) closes the tab the
    /// app opened for it, though the hosted page does not look like a provider's sign-in page.
    @Test func theCmuxSignInTabClosesOnItsCallback() throws {
        let (apps, cleanup) = try Self.apps()
        defer { cleanup() }
        var routed: [URL] = [], closed = 0
        apps.openOwnURL = { routed.append($0) }
        apps.isOwnHandoff = { $0.host == "auth-callback" }
        apps.closesHandoffTab = { _ in false }
        let signIn = try #require(URL(string: "https://cmux.com/handler/native-sign-in?cmux_auth_state=s"))
        let callback = try #require(URL(string: "cmux-nightly://auth-callback?cmux_auth_state=s"))
        apps.noteFlowPage(signIn)
        apps.open(callback, from: URL(string: "https://cmux.com/handler/after-sign-in"), userGesture: false,
                  firstPage: URL(string: "https://cmux.com/handler/sign-in"), requestedPage: signIn, close: { closed += 1 }) { _, _, _ in }
        #expect(routed == [callback] && closed == 1)
    }

    /// Any other link in this app's scheme still asks, and on Allow goes to the app's own route, never Launch Services.
    @Test func otherOwnLinksAskThenRouteInProcess() throws {
        let (apps, cleanup) = try Self.apps()
        defer { cleanup() }
        var routed: [URL] = [], answer: ((BrowserPromptResponse) -> Void)?, closed = 0
        apps.openOwnURL = { routed.append($0) }
        apps.isOwnHandoff = { _ in false }
        apps.closesHandoffTab = { _ in true }
        let link = try #require(URL(string: "cmux-nightly://tab/open?url=x"))

        apps.open(link, from: URL(string: "https://example.test"), userGesture: true, close: { closed += 1 }) { kind, _, reply in
            if case .openExternalApp(_, let scheme) = kind { #expect(scheme == "cmux-nightly") }
            answer = reply
        }
        #expect(routed.isEmpty)
        let reply = try #require(answer)
        reply(.allowOnce)
        #expect(routed == [link] && closed == 0)
    }

    /// Another app's scheme is not ours: the own route never sees it.
    @Test func otherAppsSchemesAreNotOwn() throws {
        let (apps, cleanup) = try Self.apps()
        defer { cleanup() }
        var routed = 0
        apps.openOwnURL = { _ in routed += 1 }
        apps.isOwnHandoff = { _ in true }
        let slack = try #require(URL(string: "slack://open"))
        #expect(!apps.openOwn(slack, from: nil, firstPage: nil, userGesture: false, ask: { _, _, _ in }, close: nil))
        #expect(routed == 0)
    }

    private static func apps() throws -> (BrowserExternalApps, () -> Void) {
        let suite = "BrowserExternalAppConsentTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (BrowserExternalApps(defaults: defaults, ownSchemes: ["cmux-nightly"]), { defaults.removePersistentDomain(forName: suite) })
    }
}

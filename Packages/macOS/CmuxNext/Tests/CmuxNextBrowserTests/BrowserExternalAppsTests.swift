@testable import CmuxNextBrowser
import Foundation
import Testing

/// A page's navigations to other apps (BrowserExternalApps): a sign-in
/// provider returning to its app by redirect or script, with no click, asks in
/// the prompt bar instead of being dropped
/// (https://github.com/manaflow-ai/cmux/issues/38296), and a script cannot
/// stack those questions in one tab.
@MainActor @Suite struct BrowserExternalAppsTests {
    final class Harness {
        let suite = "BrowserExternalAppsTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        var opened: [URL] = []
        var asks: [(kind: BrowserPromptKind, site: String, answer: (BrowserPromptResponse) -> Void)] = []
        /// The questions each tab's prompt bar still holds (its pending prompts).
        var pending: [Int: [(BrowserPromptKind, String)]] = [:]
        var apps: BrowserExternalApps!

        @MainActor init() {
            defaults = UserDefaults(suiteName: suite)!
            apps = BrowserExternalApps(
                defaults: defaults,
                appFor: { $0.scheme == "nobody" ? nil : URL(fileURLWithPath: "/Applications/Some App.app") },
                opener: { [unowned self] in opened.append($0) })
        }

        deinit { UserDefaults.standard.removePersistentDomain(forName: suite) }

        @MainActor func open(_ url: String, from page: String? = "https://login.example.com/authorize",
                             gesture: Bool, tab: Int = 0) {
            apps.open(URL(string: url)!, from: page.flatMap(URL.init(string:)), userGesture: gesture,
                      asking: { [unowned self] kind, site in pending[tab, default: []].contains { $0 == (kind, site) } }) { kind, site, answer in
                pending[tab, default: []].append((kind, site))
                asks.append((kind, site, { [unowned self] response in
                    if let index = pending[tab]?.firstIndex(where: { $0 == (kind, site) }) { pending[tab]?.remove(at: index) }
                    answer(response)
                }))
            }
        }
    }

    static let callback = "someapp://callback?code=abc&state=xyz"

    @Test func redirectToAnotherAppAsksThenOpensOnOpen() {
        let h = Harness()
        h.open(Self.callback, gesture: false)
        #expect(h.opened.isEmpty)
        #expect(h.asks.count == 1)
        #expect(h.asks.first?.kind == .openExternalApp(app: "Some App", scheme: "someapp"))
        h.asks[0].answer(.allowOnce)
        #expect(h.opened == [URL(string: Self.callback)!])
    }

    @Test func cancellingARedirectOpensNothingAndTheNextOneAsksAgain() {
        let h = Harness()
        h.open(Self.callback, gesture: false)
        h.asks[0].answer(.cancel)
        #expect(h.opened.isEmpty)
        h.open(Self.callback, gesture: false)
        #expect(h.asks.count == 2)
    }

    @Test func aWellKnownSchemeWithoutAClickAsksToo() {
        let h = Harness()
        h.open("mailto:someone@example.com", gesture: false)
        #expect(h.opened.isEmpty)
        #expect(h.asks.count == 1)
        h.open("mailto:someone@example.com", gesture: true)
        #expect(h.opened == [URL(string: "mailto:someone@example.com")!])
    }

    /// A redirect's question has no site, so it offers no "Always allow" and
    /// never inherits the previous page's choice.
    @Test func aRedirectNeitherOffersNorUsesAlwaysAllow() {
        let h = Harness()
        h.open(Self.callback, gesture: true)
        #expect(h.asks.first?.site == "https://login.example.com")
        h.asks[0].answer(.allow)
        h.open(Self.callback, gesture: true)
        #expect(h.asks.count == 1 && h.opened.count == 2)
        h.open(Self.callback, gesture: false)
        #expect(h.asks.count == 2 && h.opened.count == 2)
        #expect(h.asks[1].site.isEmpty)
    }

    @Test func repeatedRedirectsAskOnceWhileTheQuestionIsOpen() {
        let h = Harness()
        for _ in 0..<5 { h.open(Self.callback, gesture: false) }
        #expect(h.asks.count == 1)
        // Another scheme is its own question; a click always asks.
        h.open("otherapp://x", gesture: false)
        h.open(Self.callback, gesture: true)
        #expect(h.asks.count == 3)
        // Answered, the next redirect asks again.
        h.asks[0].answer(.cancel)
        h.open(Self.callback, gesture: false)
        #expect(h.asks.count == 4)
    }

    @Test func aQuestionInOneTabDoesNotSilenceAnother() {
        let h = Harness()
        h.open(Self.callback, gesture: false, tab: 1)
        h.open(Self.callback, gesture: false, tab: 2)
        #expect(h.asks.count == 2)
        h.asks[1].answer(.allowOnce)
        #expect(h.opened == [URL(string: Self.callback)!])
    }

    @Test func aSchemeNoAppOpensDoesNothing() {
        let h = Harness()
        h.open("nobody://x", gesture: false)
        h.open("nobody://x", gesture: true)
        #expect(h.asks.isEmpty && h.opened.isEmpty)
    }
}

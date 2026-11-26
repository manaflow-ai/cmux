#if os(iOS)
import CmuxMobileModel
import Foundation
import Testing
import WebKit
@testable import CmuxMobileWorkspaces

/// Settings → Browser → Open New Pages: each choice against each kind of page, and the
/// rule placing a tab once (the person's Open on iPhone / Mirror from Mac wins after).
@MainActor @Suite(.serialized) struct BrowserPagePlacementTests {
    typealias Placement = BrowserPagePlacement

    func defaults() -> UserDefaults {
        let name = "browser-placement-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func native(_ preference: BrowserOpenDefault, readsFiles: Bool = true, saved: UserDefaults? = nil) -> NativeBrowserTabs {
        let native = NativeBrowserTabs(defaults: saved ?? defaults())
        native.preference = { preference }
        native.seedWindow = .zero
        if readsFiles { native.readMacHTML = { _, _ in "<html><title>Report</title><h1>Report</h1></html>" } }
        return native
    }

    func until(_ check: () -> Bool) async {
        for _ in 0..<400 where !check() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    // MARK: The rule, every choice × every page kind

    @Test(arguments: [
        // Automatic
        ("https://example.com/docs", BrowserOpenDefault.automatic, true, Placement.Target.phone, Placement.Reason.publicPage),
        ("file:///Users/me/artifacts/report.html", .automatic, true, .phone, .htmlFile),
        ("https://github.com/manaflow-ai/cmux/pull/1", .automatic, true, .stream, .signInSite),
        ("https://app.example.com/login", .automatic, true, .stream, .signInSite),
        ("https://accounts.example.com/", .automatic, true, .stream, .signInSite),
        ("http://localhost:3000/", .automatic, true, .phone, .forwardedLocalhost),
        ("http://localhost:3000/", .automatic, false, .stream, .localhostNotForwarded),
        ("http://studio.local:5000", .automatic, true, .stream, .privateNetwork),
        ("http://mac-mini.tail137216.ts.net:3000", .automatic, true, .stream, .privateNetwork),
        ("file:///Users/me/shot.png", .automatic, true, .stream, .macOnly),
        ("view-source:https://example.com", .automatic, true, .stream, .macOnly),
        ("about:blank", .automatic, true, .stream, .blank),
        // Always on iPhone
        ("https://example.com/docs", .phone, true, .phone, .alwaysPhone),
        ("file:///Users/me/artifacts/report.html", .phone, true, .phone, .htmlFile),
        ("https://github.com/manaflow-ai/cmux/pull/1", .phone, true, .phone, .alwaysPhone),
        ("http://localhost:3000/", .phone, true, .phone, .forwardedLocalhost),
        ("http://localhost:3000/", .phone, false, .stream, .localhostNotForwarded),
        ("http://studio.local:5000", .phone, true, .phone, .alwaysPhone),
        ("file:///Users/me/shot.png", .phone, true, .stream, .macOnly),
        ("about:blank", .phone, true, .phone, .alwaysPhone),
        // Always stream
        ("https://example.com/docs", .stream, true, .stream, .alwaysStream),
        ("file:///Users/me/artifacts/report.html", .stream, true, .stream, .alwaysStream),
        ("http://localhost:3000/", .stream, true, .stream, .alwaysStream),
        ("about:blank", .stream, true, .stream, .alwaysStream),
    ])
    func eachChoiceForEachKindOfPage(_ address: String, _ preference: BrowserOpenDefault, _ forwards: Bool,
                                     _ target: Placement.Target, _ reason: Placement.Reason) {
        let decision = Placement.decide(URL(string: address), preference: preference, forwardsLocalhost: forwards)
        #expect(decision == Placement(target, reason), "\(address) with \(preference)")
    }

    @Test func noAddressIsABlankTab() {
        #expect(Placement.decide(nil, preference: .automatic, forwardsLocalhost: true) == Placement(.stream, .blank))
        #expect(Placement.kind(of: nil) == .blank)
    }

    @Test(arguments: [
        ("https://www.github.com/x", true), ("https://gist.github.com/x", true), ("https://linear.app/cmux/issue/CMUX-1", true),
        ("https://docs.google.com/document/d/1", true), ("https://example.com/oauth/authorize", true),
        ("https://example.com/auth/callback", true), ("https://example.com/signin", true),
        ("https://example.com/", false), ("https://developer.mozilla.org/en-US/", false), ("https://example.com/author", false),
        ("https://notgithub.com/", false), ("https://example.com/logins-are-fun", false),
    ])
    func signInSites(_ address: String, _ needs: Bool) throws {
        #expect(Placement.needsMacSignIn(try #require(URL(string: address))) == needs, "\(address)")
    }

    @Test func htmlFilesByExtension() throws {
        for (address, html) in [("file:///a/report.html", true), ("file:///a/REPORT.HTM", true), ("file:///a/x.xhtml", true),
                                ("file:///a/notes.md", false), ("https://example.com/a.html", false)] {
            #expect(Placement.isMacHTMLFile(try #require(URL(string: address))) == html, "\(address)")
        }
    }

    @Test func theSettingIsReadFromItsKey() {
        let saved = defaults()
        #expect(BrowserOpenDefault.current(saved) == .automatic, "an install that never chose")
        saved.set("stream", forKey: BrowserOpenDefault.defaultsKey)
        #expect(BrowserOpenDefault.current(saved) == .stream)
        saved.set("bogus", forKey: BrowserOpenDefault.defaultsKey)
        #expect(BrowserOpenDefault.current(saved) == .automatic)
        let store = SettingsStore(defaults: saved)
        store.browserOpenDefault = .phone
        #expect(BrowserOpenDefault.current(saved) == .phone, "Settings writes the key the tabs read")
    }

    // MARK: Placing tabs once

    @Test func tabsOpenBeforeTheFirstListStayAsTheyWere() {
        let native = native(.automatic)
        let first = native.listed(macID: "mac", browserTabs: [("t1", URL(string: "https://example.com")), ("t2", URL(string: "file:///r/report.html"))])
        #expect(first.isEmpty)
        #expect(!native.isNative(tab: "t1", macID: "mac") && !native.isNative(tab: "t2", macID: "mac"))
        #expect(native.isPlaced(tab: "t1", macID: "mac"))
    }

    @Test func aNewTabOpensWhereTheRuleSays() {
        let native = native(.automatic)
        native.listed(macID: "mac", browserTabs: [("old", URL(string: "https://example.com"))])
        let onPhone = native.listed(macID: "mac", browserTabs: [
            ("old", URL(string: "https://example.com")),
            ("report", URL(string: "file:///Users/me/artifacts/report.html")),
            ("pr", URL(string: "https://github.com/manaflow-ai/cmux/pull/1")),
            ("docs", URL(string: "https://example.org/docs")),
            ("dev", URL(string: "http://localhost:3000")),
        ])
        #expect(onPhone == ["report", "docs"])
        #expect(native.isNative(tab: "report", macID: "mac"))
        #expect(!native.isNative(tab: "pr", macID: "mac"), "a signed-in site streams")
        #expect(!native.isNative(tab: "dev", macID: "mac"), "this Mac doesn't forward localhost")
        #expect(native.lastPlacement[NativeBrowserTabs.key(tab: "pr", macID: "mac")] == Placement(.stream, .signInSite))
    }

    @Test func alwaysStreamLeavesEveryNewTabOnTheMac() {
        let native = native(.stream)
        native.listed(macID: "mac", browserTabs: [])
        let onPhone = native.listed(macID: "mac", browserTabs: [("a", URL(string: "https://example.com")), ("b", URL(string: "file:///r.html"))])
        #expect(onPhone.isEmpty)
    }

    @Test func alwaysOnIPhoneOpensSignedInSitesHereToo() {
        let native = native(.phone)
        native.listed(macID: "mac", browserTabs: [])
        let onPhone = native.listed(macID: "mac", browserTabs: [("pr", URL(string: "https://github.com/x")), ("img", URL(string: "file:///a.png"))])
        #expect(onPhone == ["pr"], "a Mac-only file still streams")
    }

    @Test func anHTMLFileStaysMirroredWhenNoLinkReadsFiles() {
        let native = native(.automatic, readsFiles: false)
        native.listed(macID: "mac", browserTabs: [])
        #expect(native.listed(macID: "mac", browserTabs: [("r", URL(string: "file:///r/report.html"))]).isEmpty)
    }

    @Test func thePersonsChoiceWinsOverTheRule() {
        let native = native(.automatic)
        native.listed(macID: "mac", browserTabs: [])
        native.listed(macID: "mac", browserTabs: [("docs", URL(string: "https://example.org"))])
        #expect(native.isNative(tab: "docs", macID: "mac"))
        // Mirror from Mac: the tab stays mirrored on the next lists.
        _ = native.close(tab: "docs", macID: "mac")
        native.listed(macID: "mac", browserTabs: [("docs", URL(string: "https://example.org"))])
        #expect(!native.isNative(tab: "docs", macID: "mac"))
        #expect(native.place(tab: "docs", macID: "mac", url: URL(string: "https://example.org")) == nil, "placed once")
    }

    @Test func aTabSentToTheMacOnPurposeStaysThere() {
        let native = native(.phone)
        native.listed(macID: "mac", browserTabs: [])
        native.keepWhereItIs(tab: "link", macID: "mac")
        #expect(native.listed(macID: "mac", browserTabs: [("link", URL(string: "https://example.com"))]).isEmpty)
    }

    @Test func aPlaceholderTabKeepsItsPlacementWhenItBecomesReal() {
        let native = native(.automatic)
        native.listed(macID: "mac", browserTabs: [])
        native.place(tab: "pending-1", macID: "mac", url: URL(string: "https://example.org"))
        native.rename(tab: "pending-1", to: "s12")
        #expect(native.isPlaced(tab: "s12", macID: "mac") && native.isNative(tab: "s12", macID: "mac"))
        #expect(native.listed(macID: "mac", browserTabs: [("s12", URL(string: "https://example.org"))]).isEmpty)
    }

    @Test func placementsAreRememberedAcrossLaunches() {
        let saved = defaults()
        let first = native(.automatic, saved: saved)
        first.listed(macID: "mac", browserTabs: [("old", URL(string: "https://example.com"))])
        first.listed(macID: "mac", browserTabs: [("old", nil), ("new", URL(string: "https://example.org"))])
        _ = first.close(tab: "new", macID: "mac")
        let relaunched = native(.automatic, saved: saved)
        // Not a first list any more, and both tabs were placed: nothing moves.
        #expect(relaunched.listed(macID: "mac", browserTabs: [("old", URL(string: "https://example.com")), ("new", URL(string: "https://example.org"))]).isEmpty)
        #expect(relaunched.listed(macID: "mac", browserTabs: [("later", URL(string: "https://example.net"))]) == ["later"])
    }

    @Test func aPlacedTabMakesNoWebViewUntilShown() {
        let native = native(.automatic)
        native.listed(macID: "mac", browserTabs: [])
        native.listed(macID: "mac", browserTabs: [("docs", URL(string: "https://example.org/a"))])
        let model = native.model(tab: "docs", macID: "mac")
        #expect(model?.url?.absoluteString == "https://example.org/a", "made on first show, at the Mac's address")
    }

    // MARK: An HTML file on the Mac, shown on the phone

    @Test func anHTMLFileFromTheMacLoadsInThePhonesWebView() async throws {
        let native = native(.automatic)
        let file = try #require(URL(string: "file:///Users/me/artifacts/report.html"))
        let model = native.open(tab: "report", macID: "mac", at: file)
        await until { model.title == "Report" }
        #expect(model.title == "Report")
        #expect(model.url == file, "the bar shows the Mac's file, not about:blank")
        #expect(model.problem == nil)
    }

    @Test func aFileTheMacWontReadSaysWhyAndOffersTheMirror() async throws {
        let native = native(.automatic)
        native.readMacHTML = { _, _ in throw ProbeError() }
        let file = try #require(URL(string: "file:///private/tmp/report.html"))
        let model = native.open(tab: "report", macID: "mac", at: file)
        await until { model.problem != nil }
        #expect(model.problem?.isMacOnly == true)
        #expect(model.problem?.detail?.contains("couldn't read report.html") == true)
    }

    struct ProbeError: LocalizedError { var errorDescription: String? { "/private/tmp isn't inside a workspace folder." } }
}
#endif

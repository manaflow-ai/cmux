@testable import CmuxNextBrowser
import Foundation
import Testing
import WebKit

/// Same-site WebKit browser tabs share a WebContent process above the renderer limit, as Chrome reuses a same-site
/// renderer once `RenderProcessHostImpl::IsProcessLimitReached` (content/browser/renderer_host/
/// render_process_host_impl.cc, `GetExistingProcessHost` and `IsSuitableHost`): below the limit every tab has its
/// own process; at it, a new tab joins a live process whose every tab is of its site (scheme and eTLD+1), never a
/// process of another site, of another profile, or one that holds two sites; incognito never joins a normal tab.
/// A joined tab is made with the process's tab as its `_relatedWebView`.
///
/// The tabs' first URLs are `.test` names, which never resolve: only the process choice made when the web view is
/// made is under test. Process ids are the test's (`processIdentifier`): none (every process still starting, one
/// per tab or per joined group) unless a test names them.
@MainActor @Suite(.serialized) struct WebKitProcessReuseTests {
    /// `test`, `io` and the private suffix `github.io`, as the bundled list has them.
    private static let suffixes = PublicSuffixList(listText: "test\nio\ngithub.io\n")

    private final class Rig {
        let reuse: WebKitProcessReuse
        let engine: WebKitEngine
        var pids: [ObjectIdentifier: Int32] = [:]
        /// The rig's tabs: the engine holds them weakly.
        private var tabs: [WebKitTab] = []

        init(limit: Int, suffixes: PublicSuffixList? = WebKitProcessReuseTests.suffixes) {
            reuse = WebKitProcessReuse(rendererLimit: limit, publicSuffixes: suffixes)
            engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory(), processReuse: reuse)
            reuse.processIdentifier = { [unowned self] tab in self.pids[ObjectIdentifier(tab)] }
        }

        func tab(_ url: String, profile: BrowserProfileID = .default, pid: Int32? = nil) -> WebKitTab {
            let tab = engine.makeWebKitTab(profile: profile, initialURL: URL(string: url))
            if let pid { pids[ObjectIdentifier(tab)] = pid }
            tabs.append(tab)
            return tab
        }

        /// Ends every tab's load.
        func close() {
            for tab in tabs { tab.close() }
        }
    }

    private func related(_ tab: WebKitTab) -> WKWebView? {
        tab.webView.configuration.value(forKey: "_relatedWebView") as? WKWebView
    }

    @Test func belowTheLimitEveryTabStartsItsOwnProcess() {
        let rig = Rig(limit: 3)
        defer { rig.close() }
        _ = rig.tab("https://a.test/1")
        let other = rig.tab("https://b.test/1")
        let sameSite = rig.tab("https://www.a.test/2")  // 2 live processes, below 3

        #expect(sameSite.processAnchor == nil)
        #expect(related(sameSite) == nil)
        #expect(related(other) == nil)
    }

    @Test func atTheLimitASameSiteTabJoinsItsSiteAndACrossSiteTabDoesNot() {
        let rig = Rig(limit: 2)
        defer { rig.close() }
        let a = rig.tab("https://a.test/1"), b = rig.tab("https://b.test/1")
        let sameSite = rig.tab("https://mail.a.test/2")
        let crossSite = rig.tab("https://c.test/1")
        let otherSameSite = rig.tab("https://b.test/2")

        #expect(sameSite.processAnchor === a)
        #expect(related(sameSite) === a.webView)
        #expect(crossSite.processAnchor == nil)
        #expect(related(crossSite) == nil)
        #expect(otherSameSite.processAnchor === b)
    }

    @Test func theSchemeIsPartOfTheSite() {
        let rig = Rig(limit: 1)
        defer { rig.close() }
        _ = rig.tab("https://a.test/1")
        let plain = rig.tab("http://a.test/2")

        #expect(plain.processAnchor == nil)
        #expect(related(plain) == nil)
    }

    @Test func anIncognitoTabNeverJoinsANormalTabsProcess() {
        let rig = Rig(limit: 1)
        defer { rig.close() }
        let incognito = rig.engine.stores.offTheRecord.begin()
        let normal = rig.tab("https://a.test/1")
        let firstPrivate = rig.tab("https://a.test/2", profile: incognito)
        let secondPrivate = rig.tab("https://a.test/3", profile: incognito)
        let secondNormal = rig.tab("https://a.test/4")

        #expect(firstPrivate.processAnchor == nil)
        #expect(related(firstPrivate) == nil)
        #expect(secondPrivate.processAnchor === firstPrivate)
        #expect(secondNormal.processAnchor === normal)
    }

    @Test func tabsOfOneProcessCountOnceTowardTheLimit() {
        let rig = Rig(limit: 3)
        defer { rig.close() }
        _ = rig.tab("https://a.test/1", pid: 10)
        _ = rig.tab("https://a.test/2", pid: 10)
        _ = rig.tab("https://b.test/1", pid: 11)
        let next = rig.tab("https://a.test/3")  // 2 processes (10 and 11), below 3

        #expect(next.processAnchor == nil)
        #expect(related(next) == nil)
    }

    @Test func aProcessThatHoldsTwoSitesTakesNoNewTab() {
        let rig = Rig(limit: 1)
        defer { rig.close() }
        // A popup of another site that WebKit kept in its opener's process: the process is not locked to a site.
        _ = rig.tab("https://a.test/1", pid: 10)
        _ = rig.tab("https://b.test/1", pid: 10)
        let next = rig.tab("https://a.test/2")

        #expect(next.processAnchor == nil)
        #expect(related(next) == nil)
    }

    @Test func aNewTabJoinsTheSameSiteProcessWithTheFewestTabs() {
        let rig = Rig(limit: 2)
        defer { rig.close() }
        _ = rig.tab("https://a.test/1", pid: 10)
        _ = rig.tab("https://a.test/2", pid: 10)
        let quiet = rig.tab("https://a.test/3", pid: 11)
        let next = rig.tab("https://a.test/4")

        #expect(next.processAnchor === quiet)
    }

    @Test func aClosedTabsProcessIsNotJoined() {
        let rig = Rig(limit: 1)
        defer { rig.close() }
        rig.tab("https://a.test/1").close()
        _ = rig.tab("https://b.test/1")
        let next = rig.tab("https://a.test/2")

        #expect(next.processAnchor == nil)
    }

    @Test func withoutTheSuffixListNoTabShares() {
        let rig = Rig(limit: 1, suffixes: nil)
        defer { rig.close() }
        _ = rig.tab("https://a.test/1")
        let next = rig.tab("https://a.test/2")

        #expect(next.processAnchor == nil)
        #expect(related(next) == nil)
    }

    @Test func aTabMadeBeforeTheListLandsIsJoinedOnceItHasLanded() {
        let rig = Rig(limit: 2, suffixes: nil)
        defer { rig.close() }
        // Session restore: tabs made, and a document committed, while the list is still being read.
        let early = rig.tab("https://a.test/1")
        early.processSiteCommitted()
        _ = rig.tab("https://b.test/1")
        rig.reuse.publicSuffixes = Self.suffixes
        let next = rig.tab("https://www.a.test/2")  // 2 live processes, at the limit

        #expect(early.processSite == nil)
        #expect(next.processAnchor === early)
        #expect(related(next) === early.webView)
    }

    @Test func aTabWhoseProcessEndedNeitherCountsNorTakesANewTab() {
        let rig = Rig(limit: 2)
        defer { rig.close() }
        let crashed = rig.tab("https://a.test/1")
        _ = rig.tab("https://b.test/1")
        // A crash or a jetsam kill: the tab stays open with no process (pid 0).
        crashed.webViewWebContentProcessDidTerminate(crashed.webView)
        let below = rig.tab("https://a.test/2")  // 1 live process (b), below 2
        let next = rig.tab("https://www.a.test/3")  // 2 live processes (b and below), at the limit

        #expect(crashed.processSite == nil)
        #expect(below.processAnchor == nil)
        #expect(related(below) == nil)
        #expect(next.processAnchor === below)
        #expect(related(next) === below.webView)
    }

    @Test func aSiteIsTheSchemeAndRegistrableDomainAndFailsClosed() {
        let reuse = WebKitProcessReuse(rendererLimit: 1, publicSuffixes: Self.suffixes)

        #expect(reuse.site(of: URL(string: "https://mail.a.test/x")) == WebKitProcessReuse.Site(scheme: "https", domain: "a.test"))
        #expect(reuse.site(of: URL(string: "http://a.test")) == WebKitProcessReuse.Site(scheme: "http", domain: "a.test"))
        // The private section: two github.io pages are two sites.
        #expect(reuse.site(of: URL(string: "https://one.github.io")) != reuse.site(of: URL(string: "https://two.github.io")))
        #expect(reuse.site(of: URL(string: "https://github.io")) == nil)
        #expect(reuse.site(of: URL(string: "https://127.0.0.1/")) == nil)
        #expect(reuse.site(of: URL(string: "file:///tmp/a.html")) == nil)
        #expect(reuse.site(of: nil) == nil)
        #expect(WebKitProcessReuse(rendererLimit: 0).rendererLimit == 1)
    }
}

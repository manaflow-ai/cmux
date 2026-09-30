import CoreGraphics
import Testing
@testable import CmuxNextBrowser

/// Chromium must never open a window of its own. Every request that would
/// open one becomes a cmux tab in a window cmux hosts, or cmux opens the URL
/// in a tab of its own, or cmux refuses it (incognito).
@Suite struct CEFWindowPolicyTests {
    private static let profile = "/p/Profiles/default"

    private func request(_ kind: CEFWindowRequest.Kind, _ disposition: CEFDisposition = .newForegroundTab,
                         source: Int32 = 0, profile: String = profile,
                         bounds: CGRect? = nil) -> CEFWindowRequest {
        CEFWindowRequest(kind: kind, disposition: disposition, sourceBrowser: source, bounds: bounds,
                         url: "https://chromewebstore.google.com/", profilePath: profile)
    }

    private func candidate(_ anchor: Int32, source: Bool = false, lastShown: Bool = false,
                           visible: Bool = true, profile: String = profile) -> CEFWindowCandidate {
        CEFWindowCandidate(anchor: anchor, profilePath: profile, holdsSource: source,
                           lastShown: lastShown, visible: visible)
    }

    /// A link from chrome://extensions (the Chrome Web Store link) opens in
    /// the window of the page that asked, not in the last shown pane.
    @Test func aLinkFromAPageOpensInThatPagesWindow() {
        let decision = CEFWindowPolicy.decide(
            request(.tab, source: 7),
            candidates: [candidate(1, lastShown: true), candidate(2, source: true)]
        )
        #expect(decision == .insert(anchor: 2, disposition: .foregroundTab))
    }

    /// Chrome UI and extension backgrounds have no source tab: the last shown
    /// pane gets the tab.
    @Test func noSourceGoesToTheLastShownPane() {
        let decision = CEFWindowPolicy.decide(
            request(.window, .newWindow),
            candidates: [candidate(1, visible: false), candidate(2, lastShown: true), candidate(3)]
        )
        #expect(decision == .insert(anchor: 2, disposition: .foregroundTab))
    }

    /// window.open with features, OAuth popups, windows.create({type:'popup'})
    /// keep the popup disposition (and window.opener) as a cmux tab.
    @Test func popupsStayPopups() {
        let decision = CEFWindowPolicy.decide(
            request(.popup, .newPopup, source: 4, bounds: CGRect(x: 0, y: 0, width: 400, height: 300)),
            candidates: [candidate(9, source: true)]
        )
        #expect(decision == .insert(anchor: 9, disposition: .popup))
    }

    @Test func backgroundTabsStayInTheBackground() {
        let decision = CEFWindowPolicy.decide(request(.tab, .newBackgroundTab, source: 4),
                                              candidates: [candidate(9, source: true)])
        #expect(decision == .insert(anchor: 9, disposition: .backgroundTab))
    }

    /// "Open Link in Incognito Window", Cmd-Shift-N, windows.create({incognito})
    /// open nothing in Chromium: cmux opens a cmux incognito window (or a
    /// tab of the source's incognito window). A normal tab would keep the
    /// history the user wanted to keep out.
    @Test func incognitoRequestsOpenACmuxIncognitoWindow() {
        #expect(CEFWindowPolicy.decide(request(.offTheRecord, .offTheRecord), candidates: [candidate(1, lastShown: true)])
            == .openOffTheRecord(url: "https://chromewebstore.google.com/"))
        #expect(CEFWindowPolicy.decide(request(.tab, .offTheRecord), candidates: [candidate(1, lastShown: true)])
            == .openOffTheRecord(url: "https://chromewebstore.google.com/"))
    }

    /// A page in an incognito window opens its tabs and popups in its own
    /// off-the-record Chromium window, never in a normal one.
    @Test func anIncognitoPageStaysInItsOwnStore() {
        let otr = "cmux-otr:0B1C"
        let decision = CEFWindowPolicy.decide(
            request(.tab, source: 7, profile: otr),
            candidates: [candidate(1, lastShown: true), candidate(2, source: true, profile: otr)]
        )
        #expect(decision == .insert(anchor: 2, disposition: .foregroundTab))
    }

    /// A request from a store cmux cannot name (Chromium reports an
    /// off-the-record profile by its parent's path) never becomes a normal
    /// tab: it could carry an incognito page's URL into the normal profile.
    @Test func aRequestFromAnUnknownStoreIsRefusedNotOpenedAsANormalTab() {
        var unknown = request(.window, .newWindow, profile: "/p/Default")
        unknown.persistentProfile = false
        #expect(CEFWindowPolicy.decide(unknown, candidates: [candidate(1, lastShown: true)]) == .refuse(.noWindow))
        #expect(CEFWindowPolicy.decide(unknown, candidates: []) == .refuse(.noWindow))
    }

    /// A tab can only join a Chromium window of its own profile; with none,
    /// cmux opens the URL in a new tab itself (Chromium makes no window).
    @Test func anotherProfilesWindowIsNeverUsed() {
        let decision = CEFWindowPolicy.decide(
            request(.tab, profile: "/p/Profiles/work"),
            candidates: [candidate(1, lastShown: true)]
        )
        #expect(decision == .openInNewTab(url: "https://chromewebstore.google.com/", disposition: .foregroundTab))
    }

    @Test func noWindowAtAllOpensACmuxTab() {
        #expect(CEFWindowPolicy.decide(request(.window, .newWindow), candidates: [])
            == .openInNewTab(url: "https://chromewebstore.google.com/", disposition: .foregroundTab))
    }

    /// Every disposition Chromium can send maps to a cmux tab or to nothing;
    /// none maps to a window.
    @Test func dispositionsMapToTabs() {
        #expect(CEFDisposition(raw: 3).tabDisposition == .foregroundTab)
        #expect(CEFDisposition(raw: 4).tabDisposition == .backgroundTab)
        #expect(CEFDisposition(raw: 5).tabDisposition == .popup)
        #expect(CEFDisposition(raw: 6).tabDisposition == .foregroundTab)
        #expect(CEFDisposition(raw: 2).tabDisposition == .foregroundTab)
        #expect(CEFDisposition(raw: 10).tabDisposition == .foregroundTab)
        #expect(CEFDisposition(raw: 1).tabDisposition == nil)
        #expect(CEFDisposition(raw: 7).tabDisposition == nil)
        #expect(CEFDisposition(raw: 99) == .unknown)
    }

    /// AFTER_CREATED carries the opener, its disposition and window features,
    /// so a popup the fork placed opens as a popup, a background tab stays
    /// in the background.
    @Test func afterCreatedCarriesTheOpenerAndDisposition() {
        let event = CEFShimEvent(kind: 2, browser: 12, request: 0, a: 0, b: (Int64(7) << 32) | 5,
                                 s1: "10,20,400,300", s2: "")
        #expect(event == .afterCreated(browser: 12, request: 0, window: 0, created: CEFCreatedBy(
            opener: 7, disposition: .newPopup, features: CGRect(x: 10, y: 20, width: 400, height: 300)
        )))
        #expect(CEFShimEvent(kind: 26, browser: 3, request: 34001, a: 0, b: 0, s1: "", s2: "")
            == .chromeCommand(browser: 3, command: 34001))
    }
}

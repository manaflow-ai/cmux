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
    /// open nothing: a normal tab would keep the history the user wanted
    /// to keep out.
    @Test func incognitoIsRefused() {
        #expect(CEFWindowPolicy.decide(request(.offTheRecord, .offTheRecord), candidates: [candidate(1, lastShown: true)])
            == .refuse(.offTheRecord))
        #expect(CEFWindowPolicy.decide(request(.tab, .offTheRecord), candidates: [candidate(1, lastShown: true)])
            == .refuse(.offTheRecord))
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
}

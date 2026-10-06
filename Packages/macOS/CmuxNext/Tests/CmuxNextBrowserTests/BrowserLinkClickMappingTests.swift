import AppKit
import Testing
@testable import CmuxNextBrowser

/// R123: modified link clicks match Chrome by default and follow the
/// user's `browser.links.*` mapping in both engines, through one pure
/// mapping (`BrowserLinkClickMapping`, `CEFLinkClicks.placement`).
@MainActor
@Suite struct BrowserLinkClickMappingTests {
    private static let custom = BrowserLinkClickMapping(cmdClick: .foregroundTab, cmdShiftClick: .newWindow,
                                                        shiftClick: .currentTab, optionClick: .backgroundTab,
                                                        middleClick: .currentTab)

    @Test func gesturesFromModifiersAndButtons() {
        #expect(BrowserLinkGesture(flags: [], button: 0) == .plain)
        #expect(BrowserLinkGesture(flags: [.control], button: 0) == .plain)
        #expect(BrowserLinkGesture(flags: [.command], button: 0) == .cmd)
        #expect(BrowserLinkGesture(flags: [.command, .shift], button: 0) == .cmdShift)
        #expect(BrowserLinkGesture(flags: [.command, .option], button: 0) == .cmd)
        #expect(BrowserLinkGesture(flags: [.command], button: 2) == .cmd)
        #expect(BrowserLinkGesture(flags: [.shift], button: 0) == .shift)
        #expect(BrowserLinkGesture(flags: [.option], button: 0) == .option)
        #expect(BrowserLinkGesture(flags: [.shift, .option], button: 0) == .plain)
        #expect(BrowserLinkGesture(flags: [], button: 2) == .middle)
        #expect(BrowserLinkGesture(flags: [.shift], button: 2) == .middleShift)
    }

    @Test func chromeDefaults() {
        let chrome = BrowserLinkClickMapping.chrome
        #expect(chrome.action(for: .plain) == .currentTab)
        #expect(chrome.action(for: .cmd) == .backgroundTab)
        #expect(chrome.action(for: .middle) == .backgroundTab)
        #expect(chrome.action(for: .cmdShift) == .foregroundTab)
        #expect(chrome.action(for: .middleShift) == .foregroundTab)
        #expect(chrome.action(for: .shift) == .newWindow)
        #expect(chrome.action(for: .option) == .download)
    }

    /// A plain click is never configurable; Shift-middle follows Shift-Cmd.
    @Test func customMappingDrivesEveryGesture() {
        let custom = Self.custom
        #expect(custom.action(for: .plain) == .currentTab)
        #expect(custom.action(for: .cmd) == .foregroundTab)
        #expect(custom.action(for: .cmdShift) == .newWindow)
        #expect(custom.action(for: .middleShift) == .newWindow)
        #expect(custom.action(for: .shift) == .currentTab)
        #expect(custom.action(for: .option) == .backgroundTab)
        #expect(custom.action(for: .middle) == .currentTab)
    }

    @Test func webKitClicksFollowTheMapping() {
        typealias A = WebKitLinkClick
        let custom = Self.custom
        #expect(A(flags: [], button: 0, mapping: custom) == .pageDefault)
        #expect(A(flags: [.command], button: 0, mapping: custom) == .open(.foregroundTab))
        #expect(A(flags: [.command, .shift], button: 0, mapping: custom) == .open(.newWindow))
        #expect(A(flags: [.shift], button: 0, mapping: custom) == .navigate)
        #expect(A(flags: [.option], button: 0, mapping: custom) == .open(.backgroundTab))
        #expect(A(flags: [], button: 2, mapping: custom) == .navigate)
        let downloads = BrowserLinkClickMapping(cmdClick: .download)
        #expect(A(flags: [.command], button: 0, mapping: downloads) == .download)
    }

    // MARK: Chromium

    private func click(_ gesture: BrowserLinkGesture, at time: TimeInterval = 100) -> CEFLinkClickRecord {
        CEFLinkClickRecord(gesture: gesture, timestamp: time)
    }

    private func placement(_ disposition: CEFDisposition, _ click: CEFLinkClickRecord? = nil, now: TimeInterval = 100.2,
                           mapping: BrowserLinkClickMapping = .chrome, userGesture: Bool = true) -> CEFLinkPlacement {
        CEFLinkClicks.placement(for: disposition, userGesture: userGesture, click: click, now: now, mapping: mapping)
    }

    /// Chromium sends NEW_FOREGROUND_TAB for a plain target=_blank link and
    /// for Shift-Cmd-click; the recorded click tells them apart.
    @Test func foregroundTabDispositionUsesTheRecordedClick() {
        let custom = Self.custom
        #expect(placement(.newForegroundTab, click(.plain), mapping: custom) == .tab(.foregroundTab))
        #expect(placement(.newForegroundTab, nil, mapping: custom) == .tab(.foregroundTab))
        #expect(placement(.newForegroundTab, click(.cmdShift), mapping: custom) == .tab(.newWindow))
        #expect(placement(.newForegroundTab, click(.middleShift), mapping: custom) == .tab(.newWindow))
        #expect(placement(.newForegroundTab, click(.cmdShift), mapping: .chrome) == .tab(.foregroundTab))
    }

    @Test func aStaleClickIsIgnored() {
        let custom = Self.custom
        #expect(placement(.newForegroundTab, click(.cmdShift, at: 98), now: 100, mapping: custom) == .tab(.foregroundTab))
        // A click stamped after the request (another clock) does not count.
        #expect(placement(.newForegroundTab, click(.cmdShift, at: 101), now: 100, mapping: custom) == .tab(.foregroundTab))
        #expect(placement(.newForegroundTab, click(.cmdShift, at: 99), now: 100, mapping: custom) == .tab(.newWindow))
    }

    /// The click record only splits NEW_FOREGROUND_TAB: NEW_BACKGROUND_TAB
    /// is always the Cmd-click setting, whatever click was recorded.
    @Test func backgroundTabDispositionIsCmdClick() {
        let custom = Self.custom
        #expect(placement(.newBackgroundTab, nil, mapping: custom) == .tab(.foregroundTab))
        #expect(placement(.newBackgroundTab, click(.cmd), mapping: custom) == .tab(.foregroundTab))
        #expect(placement(.newBackgroundTab, click(.middle), mapping: custom) == .tab(.foregroundTab))
        #expect(placement(.newBackgroundTab, click(.middle)) == .tab(.backgroundTab))
        #expect(placement(.newBackgroundTab, mapping: BrowserLinkClickMapping(cmdClick: .currentTab)) == .opener)
    }

    @Test func shiftAndOptionDispositions() {
        let custom = Self.custom
        #expect(placement(.newWindow) == .tab(.newWindow))
        #expect(placement(.newWindow, mapping: custom) == .opener)
        #expect(placement(.saveToDisk) == .download)
        #expect(placement(.saveToDisk, mapping: custom) == .tab(.backgroundTab))
    }

    /// A gesture mapped to a download downloads the link in the opener
    /// (the shim's StartDownload), whatever the gesture.
    @Test func downloadOnAnyGestureDownloadsInTheOpener() {
        let downloads = BrowserLinkClickMapping(cmdClick: .download, cmdShiftClick: .download, shiftClick: .download,
                                                optionClick: .download, middleClick: .download)
        #expect(placement(.newBackgroundTab, mapping: downloads) == .download)
        #expect(placement(.newForegroundTab, click(.cmdShift), mapping: downloads) == .download)
        #expect(placement(.newForegroundTab, click(.plain), mapping: downloads) == .tab(.foregroundTab))
        #expect(placement(.newWindow, mapping: downloads) == .download)
        #expect(placement(.saveToDisk, mapping: downloads) == .download)
    }

    /// A request no user gesture caused (a script's window.open, a
    /// redirect) never follows a modified-click setting: Chrome's default
    /// for its disposition, and the recorded click does not count.
    @Test func aRequestWithoutAUserGestureIgnoresTheMapping() {
        let custom = Self.custom
        #expect(placement(.newBackgroundTab, mapping: custom, userGesture: false) == .tab(.backgroundTab))
        #expect(placement(.newWindow, mapping: custom, userGesture: false) == .tab(.newWindow))
        #expect(placement(.saveToDisk, mapping: custom, userGesture: false) == .download)
        #expect(placement(.newForegroundTab, click(.cmdShift), mapping: custom, userGesture: false) == .tab(.foregroundTab))
        let current = BrowserLinkClickMapping(cmdClick: .currentTab, shiftClick: .download)
        #expect(placement(.newBackgroundTab, mapping: current, userGesture: false) == .tab(.backgroundTab))
        #expect(placement(.newWindow, mapping: current, userGesture: false) == .tab(.newWindow))
    }

    @Test func nonLinkDispositionsIgnoreTheMapping() {
        let custom = Self.custom
        #expect(placement(.newPopup, click(.cmd), mapping: custom) == .tab(.popup))
        #expect(placement(.currentTab, click(.cmd), mapping: custom) == .chromium)
        #expect(placement(.ignoreAction, mapping: custom) == .chromium)
        #expect(placement(.newPictureInPicture, mapping: custom) == .chromium)
        #expect(placement(.switchToTab, mapping: custom) == .tab(.foregroundTab))
        #expect(placement(.offTheRecord, mapping: custom) == .tab(.foregroundTab))
    }

    // MARK: Window requests

    private func request(_ kind: CEFWindowRequest.Kind, _ disposition: CEFDisposition, source: Int32 = 4,
                         userGesture: Bool = true) -> CEFWindowRequest {
        CEFWindowRequest(kind: kind, disposition: disposition, sourceBrowser: source, bounds: nil,
                         url: "https://example.com/", userGesture: userGesture, profilePath: "/p")
    }

    private let window = [CEFWindowCandidate(anchor: 9, profilePath: "/p", holdsSource: true, lastShown: true, visible: true)]

    /// Shift-click (NEW_WINDOW from a page) opens a cmux window; the same
    /// request with no source tab (Chromium's UI, an extension) stays a tab.
    @Test func shiftClickWindowRequestsOpenACmuxWindow() {
        #expect(CEFWindowPolicy.decide(request(.window, .newWindow), candidates: window) == .insert(anchor: 9, disposition: .newWindow))
        #expect(CEFWindowPolicy.decide(request(.window, .newWindow, source: 0), candidates: window)
            == .insert(anchor: 9, disposition: .foregroundTab))
        #expect(CEFWindowPolicy.decide(request(.window, .newWindow), candidates: [])
            == .openInNewTab(url: "https://example.com/", disposition: .newWindow))
    }

    /// A gesture mapped to the current tab: Chromium opens nothing and the
    /// source tab loads the link.
    @Test func currentTabLoadsInTheSource() {
        let links = CEFLinkContext(mapping: Self.custom, clicks: [:], now: 0)
        #expect(CEFWindowPolicy.decide(request(.window, .newWindow), candidates: window, links: links)
            == .loadInSource(url: "https://example.com/"))
        #expect(CEFWindowPolicy.decide(request(.window, .newWindow, source: 0), candidates: window, links: links)
            == .insert(anchor: 9, disposition: .foregroundTab))
        let cmd = CEFLinkContext(mapping: BrowserLinkClickMapping(cmdClick: .currentTab), clicks: [:], now: 10.1)
        #expect(CEFWindowPolicy.decide(request(.tab, .newBackgroundTab), candidates: window, links: cmd)
            == .loadInSource(url: "https://example.com/"))
    }

    /// A window request carries its user gesture (the fork's request): a
    /// script's request ignores the mapping, a click mapped to a download
    /// downloads in the source tab and Chromium opens nothing.
    @Test func windowRequestsUseTheirUserGesture() {
        let links = CEFLinkContext(mapping: Self.custom, clicks: [:], now: 0)
        #expect(CEFWindowPolicy.decide(request(.window, .newWindow, userGesture: false), candidates: window, links: links)
            == .insert(anchor: 9, disposition: .newWindow))
        let downloads = CEFLinkContext(mapping: BrowserLinkClickMapping(cmdClick: .download), clicks: [:], now: 0)
        #expect(CEFWindowPolicy.decide(request(.tab, .newBackgroundTab), candidates: window, links: downloads)
            == .downloadInSource(url: "https://example.com/"))
        #expect(CEFWindowPolicy.decide(request(.tab, .newBackgroundTab, source: 0), candidates: window, links: downloads)
            == .insert(anchor: 9, disposition: .foregroundTab))
        #expect(CEFWindowPolicy.decide(request(.tab, .newBackgroundTab, userGesture: false), candidates: window, links: downloads)
            == .insert(anchor: 9, disposition: .backgroundTab))
    }

    /// The shim reports the opener's user gesture with each popup and with
    /// the AFTER_CREATED of the tab Chromium made for it.
    @Test func popupEventsCarryTheUserGesture() {
        #expect(CEFShimEvent(kind: 17, browser: 3, request: 0, a: 4, b: 1, s1: "https://e.com/", s2: "")
            == .popup(browser: 3, url: "https://e.com/", disposition: 4, userGesture: true))
        #expect(CEFShimEvent(kind: 17, browser: 3, request: 0, a: 4, b: 0, s1: "https://e.com/", s2: "")
            == .popup(browser: 3, url: "https://e.com/", disposition: 4, userGesture: false))
        let created = CEFCreatedBy(packed: (Int64(7) << 32) | (1 << 16) | 4, features: "")
        #expect(created == CEFCreatedBy(opener: 7, disposition: .newBackgroundTab, userGesture: true, features: nil))
        #expect(CEFCreatedBy(packed: (Int64(7) << 32) | 4, features: "").userGesture == false)
    }

    /// A click counts only for the page that received it: a Shift-Cmd-click
    /// on tab A never changes a NEW_FOREGROUND_TAB request from tab B.
    @Test func aClickOnAnotherPageDoesNotCount() {
        let links = CEFLinkContext(mapping: Self.custom, clicks: [7: click(.cmdShift, at: 10)], now: 10.1)
        #expect(links.placement(for: .newForegroundTab, source: 7, userGesture: true) == .tab(.newWindow))
        #expect(links.placement(for: .newForegroundTab, source: 4, userGesture: true) == .tab(.foregroundTab))
        #expect(links.placement(for: .newForegroundTab, source: 0, userGesture: true) == .tab(.foregroundTab))
        #expect(CEFWindowPolicy.decide(request(.tab, .newForegroundTab), candidates: window, links: links)
            == .insert(anchor: 9, disposition: .foregroundTab))
    }

    /// Only a click in a page window (a child window of the cmux window
    /// holding the page) inside the page and outside native UI over it is
    /// recorded; a click in a cmux window itself (strip, sidebar, omnibar)
    /// records nothing.
    @Test func onlyClicksOnAPageAreRecorded() {
        final class Token {}
        let cmuxWindow = Token(), pageWindow = Token(), otherWindow = Token()
        let main = ObjectIdentifier(cmuxWindow), page = ObjectIdentifier(pageWindow)
        let targets = [
            CEFClickTarget(browser: 7, hostWindow: main, frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                           occlusions: [CGRect(x: 0, y: 0, width: 400, height: 30)]),
            CEFClickTarget(browser: 8, hostWindow: main, frame: CGRect(x: 400, y: 0, width: 400, height: 300)),
        ]
        func hit(_ window: ObjectIdentifier, parent: ObjectIdentifier?, _ x: Double, _ y: Double) -> Int32? {
            CEFLinkClicks.browser(clickedIn: window, parent: parent, at: CGPoint(x: x, y: y), targets: targets)
        }
        #expect(hit(page, parent: main, 100, 100) == 7)
        #expect(hit(page, parent: main, 500, 100) == 8)
        #expect(hit(main, parent: nil, 100, 100) == nil, "the cmux window itself")
        #expect(hit(page, parent: main, 100, 10) == nil, "native UI over the page")
        #expect(hit(page, parent: main, 900, 100) == nil, "outside every page")
        #expect(hit(page, parent: ObjectIdentifier(otherWindow), 100, 100) == nil, "another window's child")
    }
}

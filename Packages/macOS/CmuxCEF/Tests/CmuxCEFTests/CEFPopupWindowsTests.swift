import CoreGraphics
import Foundation
import Testing
@testable import CmuxCEF

/// Extension popup windows (`chrome.windows.create({type: "popup"})`, fork
/// API 13): their tab must reach the app as a sized popup instead of being
/// closed as a tab without an opener.
@Suite
struct CEFPopupWindowsTests {
    @Test
    func popupWindowsNeedForkAPI13() {
        #expect(!CEFPopupWindows.isEnabled(forkAPIVersion: 11))
        #expect(!CEFPopupWindows.isEnabled(forkAPIVersion: 12))
        #expect(CEFPopupWindows.isEnabled(forkAPIVersion: 13))
        #expect(CEFPopupWindows.isEnabled(forkAPIVersion: 25))
    }

    @Test
    func boundsThatOnlyFollowTheHostViewAreNotFedBack() {
        let host = CGRect(x: 100, y: 80, width: 400, height: 600)
        #expect(CEFPopupWindows.isOwnPlacement(CGRect(x: 100.5, y: 80, width: 400, height: 599.5), hostFrame: host))
        #expect(!CEFPopupWindows.isOwnPlacement(CGRect(x: 100, y: 80, width: 500, height: 600), hostFrame: host))
        #expect(!CEFPopupWindows.isOwnPlacement(host, hostFrame: nil))
    }

    @Test
    func currentNavigationEntrySeedsTheAdoptedPopup() throws {
        let json = #"{"current":1,"entries":[{"url":"about:blank","title":""},{"url":"chrome-extension://abc/popup.html","title":"Vault"}]}"#
        let entry = try #require(CEFPopupWindows.currentEntry(navigationEntriesJSON: json))
        #expect(entry.url.absoluteString == "chrome-extension://abc/popup.html")
        #expect(entry.title == "Vault")
        #expect(CEFPopupWindows.currentEntry(navigationEntriesJSON: #"{"current":3,"entries":[]}"#) == nil)
    }

    @MainActor @Test
    func orphanTabWaitsWhilePopupWindowsAreOn() {
        let runtime = CEFRuntime(layout: nil)
        runtime.popupWindowsEnabled = true
        var reopened: [URL] = []
        runtime.openURLWithoutOpener = { url, _ in reopened.append(url) }

        runtime.handle(.afterCreated(browser: 42, request: 0, window: 9,
                                     created: CEFCreatedBy(opener: 0, disposition: .newPopup, features: nil)))

        // Not closed inside Chromium's tab insertion: decided on a later turn.
        #expect(reopened.isEmpty)
        #expect(runtime.deferredOrphans.contains(42))
    }

    @MainActor @Test
    func orphanOutsideAPopupWindowStillOpensElsewhere() throws {
        let runtime = CEFRuntime(layout: nil)
        runtime.popupWindowsEnabled = true
        var reopened: [URL] = []
        runtime.openURLWithoutOpener = { url, _ in reopened.append(url) }
        var created = CEFCreatedBy(opener: 0, disposition: .newForegroundTab, features: nil)
        created.url = "https://example.com/"

        runtime.handle(.afterCreated(browser: 42, request: 0, window: 5, created: created))
        runtime.resolveOrphan(42, created: created)

        #expect(reopened == [try #require(URL(string: "https://example.com/"))])
        #expect(runtime.deferredOrphans.isEmpty)
    }

    @MainActor @Test
    func orphanThatClosedMeanwhileOpensNothing() {
        let runtime = CEFRuntime(layout: nil)
        runtime.popupWindowsEnabled = true
        var reopened: [URL] = []
        runtime.openURLWithoutOpener = { url, _ in reopened.append(url) }
        var created = CEFCreatedBy(opener: 0, disposition: .newForegroundTab, features: nil)
        created.url = "https://example.com/"

        runtime.handle(.afterCreated(browser: 42, request: 0, window: 5, created: created))
        runtime.handle(.beforeClose(browser: 42))
        runtime.resolveOrphan(42, created: created)

        #expect(reopened.isEmpty)
    }

    @MainActor @Test
    func popupWindowTabOpensAsASizedPopupOverTheLastShownPage() throws {
        let runtime = CEFRuntime(layout: nil)
        runtime.popupWindowsEnabled = true
        let opener = CEFBrowser(configuration: CEFBrowserConfiguration(profile: UUID()), runtime: runtime)
        runtime.register(opener, id: 7)
        runtime.lastShownBrowser = opener
        var opened: [(CEFBrowser, CEFDisposition, Bool)] = []
        opener.onEvent = { event in
            if case .newBrowser(let popup, let disposition, _, let gesture) = event {
                opened.append((popup, disposition, gesture))
            }
        }

        runtime.deferredOrphans.insert(42)
        runtime.adoptPopupWindow(window: 9, browser: 42)

        let (popup, disposition, gesture) = try #require(opened.first)
        #expect(opened.count == 1)
        #expect(disposition == .newPopup)
        #expect(gesture)
        #expect(popup.popupWindow == 9)
        #expect(popup.browserID == 42)
        #expect(runtime.browser(id: 42) === popup)
        #expect(popup.configuration.profile == opener.configuration.profile)
        // Its orphan decision (AFTER_CREATED) no longer closes it.
        #expect(!runtime.deferredOrphans.contains(42))

        // A second report of the same window adopts nothing more.
        runtime.adoptPopupWindow(window: 9, browser: 42)
        #expect(opened.count == 1)
    }

    @MainActor @Test
    func popupWindowWithoutAnyPageIsNotAdopted() {
        let runtime = CEFRuntime(layout: nil)
        runtime.popupWindowsEnabled = true

        runtime.adoptPopupWindow(window: 9, browser: 42)

        #expect(runtime.browser(id: 42) == nil)
    }
}

/// Event order seen on fork API 23: the popup tab's AFTER_CREATED (no
/// opener) and CMUX_POPUP_WINDOW_CREATED arrive in the same turn, so the
/// orphan decision runs before the adoption.
@Suite
struct CEFPopupWindowEventOrderTests {
    @MainActor @Test
    func popupWindowEventInTheSameTurnKeepsTheOrphanTabOpen() {
        let runtime = CEFRuntime(layout: nil)
        runtime.popupWindowsEnabled = true
        var reopened: [URL] = []
        runtime.openURLWithoutOpener = { url, _ in reopened.append(url) }
        var created = CEFCreatedBy(opener: 0, disposition: .newForegroundTab, features: nil)
        created.url = "chrome-extension://abc/popup.html"

        runtime.handle(.afterCreated(browser: 42, request: 0, window: 5, created: created))
        runtime.handle(.tab(.popupWindowCreated, browser: 42, window: 9, value: 4))
        runtime.resolveOrphan(42, created: created)

        #expect(reopened.isEmpty)
    }

    @MainActor @Test
    func popupTabThatClosedBeforeAdoptionIsNotAdopted() {
        let runtime = CEFRuntime(layout: nil)
        runtime.popupWindowsEnabled = true
        let opener = CEFBrowser(configuration: CEFBrowserConfiguration(profile: UUID()), runtime: runtime)
        runtime.register(opener, id: 7)
        runtime.lastShownBrowser = opener
        var opened = 0
        opener.onEvent = { event in if case .newBrowser = event { opened += 1 } }

        runtime.handle(.tab(.popupWindowCreated, browser: 42, window: 9, value: 4))
        runtime.handle(.beforeClose(browser: 42))
        runtime.adoptPopupWindow(window: 9, browser: 42)

        #expect(opened == 0)
        #expect(runtime.browser(id: 42) == nil)
    }

    @MainActor @Test
    func unplacedPopupTabIsClaimedByItsPopupWindow() {
        let runtime = CEFRuntime(layout: nil)
        runtime.popupWindowsEnabled = true

        // AFTER_CREATED with no window yet: the tab waits for an insertion.
        runtime.handle(.afterCreated(browser: 42, request: 0, window: 0,
                                     created: CEFCreatedBy(opener: 0, disposition: .newPopup, features: nil)))
        #expect(runtime.unplacedPopups[42] != nil)

        runtime.handle(.tab(.popupWindowCreated, browser: 42, window: 9, value: 4))

        #expect(runtime.unplacedPopups[42] == nil)
        #expect(runtime.keptPopupWindows.contains(9))
    }
}

import CoreGraphics
import Foundation
import Testing
@testable import CmuxCEF

/// A tab Chromium opens for a page (`window.open`, target=_blank, Cmd-click)
/// reaches the runtime as AFTER_CREATED. The shim matches it to its request
/// by the new tab's visible URL, which a scripted `window.open` does not have
/// yet at that point: the tab arrived with no disposition, no user gesture
/// and no window features, so a sized popup opened as a tab and a Cmd-click
/// took focus.
@Suite
struct CEFPopupLedgerTests {
    @Test
    func anUnmatchedTabTakesItsOpenersOldestRequest() {
        var ledger = CEFPopupLedger()
        ledger.recordRequest(opener: 7, url: "http://a.test/one", disposition: .newPopup, userGesture: true, at: 10)
        ledger.recordRequest(opener: 7, url: "http://a.test/two", disposition: .newBackgroundTab, userGesture: true, at: 10.5)

        let first = ledger.resolve(CEFCreatedBy(opener: 7, disposition: .unknown, features: nil), opener: 7, now: 11)
        #expect(first.disposition == .newPopup)
        #expect(first.userGesture)
        #expect(first.url == "http://a.test/one")

        let second = ledger.resolve(CEFCreatedBy(opener: 7, disposition: .unknown, features: nil), opener: 7, now: 11)
        #expect(second.disposition == .newBackgroundTab)
        #expect(second.url == "http://a.test/two")
    }

    @Test
    func aPopupWindowRequestGivesTheRequestItsBounds() {
        var ledger = CEFPopupLedger()
        ledger.recordRequest(opener: 7, url: "http://a.test/sized", disposition: .newPopup, userGesture: true, at: 10)
        ledger.recordWindowBounds(source: 7, bounds: CGRect(x: 40, y: 50, width: 480, height: 360), at: 10.1)

        let created = ledger.resolve(CEFCreatedBy(opener: 7, disposition: .unknown, features: nil), opener: 7, now: 10.2)
        #expect(created.disposition == .newPopup)
        #expect(created.features == CGRect(x: 40, y: 50, width: 480, height: 360))
    }

    @Test
    func aTabWithNoOpenerIdIsCreditedToItsWindowsPage() {
        var ledger = CEFPopupLedger()
        ledger.recordRequest(opener: 7, url: "http://a.test/cmd", disposition: .newBackgroundTab, userGesture: true, at: 10)

        // Chromium reported no opener (a modified click), the window's page is 7.
        let created = ledger.resolve(.none, opener: 7, now: 10.2)
        #expect(created.opener == 7)
        #expect(created.disposition == .newBackgroundTab)
        #expect(created.url == "http://a.test/cmd")
    }

    @Test
    func aMatchedTabKeepsItsOwnDispositionAndConsumesItsRequest() {
        var ledger = CEFPopupLedger()
        ledger.recordRequest(opener: 7, url: "http://a.test/one", disposition: .newForegroundTab, userGesture: true, at: 10)
        var matched = CEFCreatedBy(opener: 7, disposition: .newForegroundTab, userGesture: true, features: nil)
        matched.url = "http://a.test/one"

        #expect(ledger.resolve(matched, opener: 7, now: 10.1) == matched)
        #expect(ledger.isEmpty)
    }

    @Test
    func staleRequestsAndOtherOpenersNeverMatch() {
        var ledger = CEFPopupLedger()
        ledger.recordRequest(opener: 7, url: "http://a.test/old", disposition: .newPopup, userGesture: true, at: 1)
        ledger.recordRequest(opener: 8, url: "http://a.test/other", disposition: .newPopup, userGesture: true, at: 10)

        let created = ledger.resolve(CEFCreatedBy(opener: 7, disposition: .unknown, features: nil), opener: 7, now: 10)
        #expect(created.disposition == .unknown)
        #expect(created.userGesture == false)
    }

    @Test
    func aClosedOpenerForgetsItsRequests() {
        var ledger = CEFPopupLedger()
        ledger.recordRequest(opener: 7, url: "http://a.test/one", disposition: .newPopup, userGesture: true, at: 10)
        ledger.forget(opener: 7)
        #expect(ledger.isEmpty)
    }

    @Test
    func onlyRequestsThatOpenATabAreRecorded() {
        var ledger = CEFPopupLedger()
        ledger.recordRequest(opener: 7, url: "file:///tmp/a.html", disposition: .currentTab, userGesture: true, at: 10)
        ledger.recordRequest(opener: 7, url: "http://a.test/save", disposition: .saveToDisk, userGesture: true, at: 10)
        #expect(ledger.isEmpty)
    }

    @Test
    func theWindowOwnerIsThePageShownInThatWindow() {
        let owners = [
            CEFPopupLedger.WindowPage(browser: 3, window: 30, isOwner: true),
            // A popup still waiting in its opener's window is not the owner.
            CEFPopupLedger.WindowPage(browser: 4, window: 40, isOwner: false),
            CEFPopupLedger.WindowPage(browser: 5, window: 40, isOwner: true),
        ]
        #expect(CEFPopupLedger.owner(ofWindow: 40, among: owners) == 5)
        #expect(CEFPopupLedger.owner(ofWindow: 30, among: owners) == 3)
        #expect(CEFPopupLedger.owner(ofWindow: 0, among: owners) == nil)
        #expect(CEFPopupLedger.owner(ofWindow: 99, among: owners) == nil)
    }
}

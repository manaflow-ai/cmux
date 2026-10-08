import Foundation
import Testing

@testable import CmuxBrowser

@MainActor
@Suite("Browser state load transaction")
struct BrowserStateLoadTransactionTests {
    @Test("storage waits until the requested navigation commits")
    func storageWaitsForNavigationCommit() {
        var events: [String] = []

        let result = BrowserStateLoadTransaction().run(
            hasNavigation: true,
            restoreFrameSelection: {},
            installCookies: {
                events.append("cookies")
                return true
            },
            navigateAndWait: {
                events.append("navigate")
                events.append("committed")
                return .committed
            },
            applyStorage: {
                events.append("storage")
                return true
            }
        )

        #expect(result == .loaded)
        #expect(events == ["cookies", "navigate", "committed", "storage"])
    }

    @Test("navigation failure does not apply target storage")
    func navigationFailureDoesNotApplyStorage() {
        var storageApplied = false

        let result = BrowserStateLoadTransaction().run(
            hasNavigation: true,
            restoreFrameSelection: {},
            installCookies: { true },
            navigateAndWait: { .failed("offline") },
            applyStorage: {
                storageApplied = true
                return true
            }
        )

        #expect(result == .navigationFailed(.failed("offline")))
        #expect(!storageApplied)
    }

    /// A saved frame selector names a frame of the page the state file loads,
    /// so it can only be checked and applied once that page is there.
    @Test("frame selection is restored after the loaded page has its storage")
    func frameSelectionWaitsForTheLoadedDocument() {
        var events: [String] = []

        let result = BrowserStateLoadTransaction().run(
            hasNavigation: true,
            restoreFrameSelection: { events.append("frame") },
            installCookies: {
                events.append("cookies")
                return true
            },
            navigateAndWait: {
                events.append("navigate")
                return .committed
            },
            applyStorage: {
                events.append("storage")
                return true
            }
        )

        #expect(result == .loaded)
        #expect(events == ["cookies", "navigate", "storage", "frame"])
    }

    @Test("a state file without a URL restores frame selection against the current page")
    func frameSelectionIsRestoredWithoutNavigation() {
        var events: [String] = []

        let result = BrowserStateLoadTransaction().run(
            hasNavigation: false,
            restoreFrameSelection: { events.append("frame") },
            installCookies: { true },
            navigateAndWait: {
                events.append("navigate")
                return .committed
            },
            applyStorage: {
                events.append("storage")
                return true
            }
        )

        #expect(result == .loaded)
        #expect(events == ["storage", "frame"])
    }

    @Test("a failed load does not restore the saved frame selection", arguments: [
        "cookies", "navigation", "storage",
    ])
    func failedLoadLeavesFrameSelectionAlone(failingStep: String) {
        var frameSelectionRestored = false

        let result = BrowserStateLoadTransaction().run(
            hasNavigation: true,
            restoreFrameSelection: { frameSelectionRestored = true },
            installCookies: { failingStep != "cookies" },
            navigateAndWait: { failingStep == "navigation" ? .failed("offline") : .committed },
            applyStorage: { failingStep != "storage" }
        )

        #expect(result != .loaded)
        #expect(!frameSelectionRestored)
    }
}

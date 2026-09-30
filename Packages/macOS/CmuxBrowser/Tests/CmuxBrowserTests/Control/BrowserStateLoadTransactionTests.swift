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
}

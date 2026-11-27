import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// A chat pushed on Home or the Feed turns with the phone while on screen
/// (LandscapeUITests testE, step 836d3f58: it stayed portrait, 402x874).
@MainActor @Suite struct AgentChatPageOrientationTests {
    @Test func reportsOnlyTheFirstChatInAndTheLastOut() {
        let pages = AgentChatPageOrientation()
        var reports: [Bool] = []
        pages.onChange = { reports.append($0) }
        let first = UUID(), second = UUID()
        pages.page(first, shows: true)
        pages.page(second, shows: true)
        pages.page(first, shows: false)
        #expect(pages.isShowing)
        pages.page(second, shows: false)
        #expect(!pages.isShowing)
        #expect(reports == [true, false])
    }

    @Test func aRepeatedReportChangesNothing() {
        let pages = AgentChatPageOrientation()
        var reports: [Bool] = []
        pages.onChange = { reports.append($0) }
        let id = UUID()
        pages.page(id, shows: true)
        pages.page(id, shows: true)
        pages.page(UUID(), shows: false)
        #expect(reports == [true])
    }
}

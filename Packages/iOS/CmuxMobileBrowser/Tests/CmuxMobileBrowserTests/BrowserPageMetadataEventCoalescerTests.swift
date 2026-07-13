import Foundation
import Testing

@testable import CmuxMobileBrowser

@MainActor
@Suite struct BrowserPageMetadataEventCoalescerTests {
    @Test func rapidPageEventsCommitOnceWithFinalValues() async {
        var commits: [BrowserPageMetadataUpdate] = []
        let coalescer = BrowserPageMetadataEventCoalescer { commits.append($0) }

        for index in 0 ..< 100 {
            coalescer.receiveTitle("Title \(index)")
            coalescer.receiveURL(URL(string: "https://example.com/\(index)")!)
        }
        await coalescer.waitForScheduledCommit()

        #expect(commits.count == 1)
        #expect(commits[0].title == "Title 99")
        #expect(commits[0].url?.absoluteString == "https://example.com/99")
    }

    @Test func flushCommitsFinalPendingValuesAndCancelsScheduledCommit() async {
        var commits: [BrowserPageMetadataUpdate] = []
        let coalescer = BrowserPageMetadataEventCoalescer { commits.append($0) }
        coalescer.receiveTitle("Final")
        coalescer.receiveURL(URL(string: "https://example.com/final")!)

        coalescer.flush()
        await coalescer.waitForScheduledCommit()

        #expect(commits.count == 1)
        #expect(commits[0].title == "Final")
        #expect(commits[0].url?.absoluteString == "https://example.com/final")
    }
}

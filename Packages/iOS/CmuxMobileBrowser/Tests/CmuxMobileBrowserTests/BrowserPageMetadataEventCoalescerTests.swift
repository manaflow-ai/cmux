import Foundation
import Testing
#if canImport(WebKit)
import WebKit
#endif

@testable import CmuxMobileBrowser

@MainActor
@Suite struct BrowserPageMetadataEventCoalescerTests {
    @Test func rapidPageEventsCommitOnceWithFinalValues() async {
        var commits: [BrowserPageMetadataUpdate] = []
        var scheduleCount = 0
        let coalescer = BrowserPageMetadataEventCoalescer(
            didSchedule: { scheduleCount += 1 },
            commit: { commits.append($0) }
        )

        for index in 0 ..< 10_000 {
            coalescer.receiveTitle("Title \(index)")
            coalescer.receiveURL(URL(string: "https://example.com/\(index)")!)
        }
        await coalescer.waitForScheduledCommit()

        #expect(scheduleCount == 1)
        #expect(commits.count == 1)
        #expect(commits[0].title == "Title 9999")
        #expect(commits[0].url?.absoluteString == "https://example.com/9999")
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

    #if canImport(UIKit) && canImport(WebKit)
    @Test(arguments: [NSURLErrorCannotConnectToHost, NSURLErrorCancelled])
    func navigationFailureInvalidatesPendingProvisionalMetadata(errorCode: Int) async {
        let committedURL = URL(string: "https://committed.example")!
        let state = BrowserSurfaceState(id: .init(rawValue: "failure-metadata"))
        state.navigationDidFinish(url: committedURL, title: "Committed")
        let coordinator = MobileBrowserView.Coordinator(state: state)
        let webView = WKWebView()
        coordinator.attach(webView: webView)
        coordinator.pageMetadataCoalescer.receiveTitle(nil)

        coordinator.webView(
            webView,
            didFail: nil,
            withError: NSError(domain: NSURLErrorDomain, code: errorCode)
        )
        await coordinator.pageMetadataCoalescer.waitForScheduledCommit()

        #expect(state.currentURL == committedURL)
        #expect(state.title == "Committed")
    }
    #endif
}

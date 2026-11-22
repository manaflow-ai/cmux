import Foundation
@testable import CmuxNextBrowser
import Testing

/// A download is named once its engine knows the page's suggested file name
/// (WebKit: when it picks the destination). `onNamed` runs then, once, and
/// always before `onFinish`, so an agent's `download.started` carries the
/// real name. Before, WebKit reported the URL's last path part ("cd").
@MainActor
struct BrowserDownloadNamingTests {
    @Test func anUnnamedDownloadReportsItsNameWhenTheEngineGivesIt() {
        let item = BrowserDownload(sourceURL: URL(string: "https://e.com/download/cd"), filename: "cd", named: false)
        var events: [String] = []
        item.onNamed { events.append("named \($0.suggestedFilename)") }
        #expect(events.isEmpty)
        item.suggestedFilename = "cd-a.txt"
        item.named()
        item.named()
        item.onFinish { _ in events.append("finished") }
        item.complete(.finished)
        #expect(events == ["named cd-a.txt", "finished"])
    }

    @Test func aDownloadThatEndsUnnamedIsNamedFirst() {
        let item = BrowserDownload(sourceURL: nil, filename: "x", named: false)
        var events: [String] = []
        item.onNamed { _ in events.append("named") }
        item.onFinish { _ in events.append("finished") }
        item.complete(.failed("no free file name"))
        #expect(events == ["named", "finished"])
    }

    @Test func aNamedDownloadRunsOnNamedAtOnce() {
        let item = BrowserDownload(sourceURL: nil, filename: "a.txt")
        var named = false
        item.onNamed { _ in named = true }
        #expect(named)
    }
}

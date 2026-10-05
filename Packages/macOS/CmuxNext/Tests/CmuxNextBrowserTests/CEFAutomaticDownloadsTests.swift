import Foundation
import Testing
@testable import CmuxNextBrowser

/// Chromium downloads ask the tab's automatic-downloads gate before they
/// start: a refused download is cancelled silently (no path, nothing in
/// the downloads list); downloads cmux starts itself never ask; a download
/// Chromium ends while the question is open is dropped.
@MainActor
@Suite struct CEFAutomaticDownloadsTests {
    typealias Harness = CEFDownloadsTests.Harness

    @Test func aRefusedDownloadIsCancelledSilently() throws {
        let h = try Harness()
        defer { h.remove() }
        var asked: [Int32] = []
        h.downloads.admit = { browser, decide in
            asked.append(browser)
            decide(false)
        }
        h.event(34, browser: 5, id: 1, s1: "https://e.com/a.zip", s2: "a.zip")
        #expect(asked == [5])
        #expect(h.fake.answers.map { $0.id } == [1])
        #expect(h.fake.answers.map { $0.path } == [""])
        #expect(h.delivered.isEmpty)
        #expect(h.names.isEmpty)
    }

    @Test func anAdmittedDownloadStartsWhenTheAnswerComes() throws {
        let h = try Harness()
        defer { h.remove() }
        var pending: ((Bool) -> Void)?
        h.downloads.admit = { _, decide in pending = decide }
        h.event(34, browser: 5, id: 2, s1: "https://e.com/b.zip", s2: "b.zip")
        #expect(h.fake.answers.isEmpty)
        #expect(h.delivered.isEmpty)
        pending?(true)
        #expect(h.fake.answers.map { $0.id } == [2])
        #expect(h.fake.answers.first?.path.isEmpty == false)
        #expect(h.delivered.map { $0.item.filename } == ["b.zip"])
    }

    @Test func downloadsCmuxStartsNeverAsk() throws {
        let h = try Harness()
        defer { h.remove() }
        var asked = 0
        h.downloads.admit = { _, decide in
            asked += 1
            decide(false)
        }
        let link = try #require(URL(string: "https://e.com/c.zip"))
        #expect(h.downloads.download(link.absoluteString, browser: 5))
        h.event(34, browser: 5, id: 3, s1: link.absoluteString, s2: "c.zip")
        #expect(h.downloads.save(link, to: h.file("picked.zip"), browser: 5))
        h.event(34, browser: 5, id: 4, s1: link.absoluteString, s2: "c.zip")
        #expect(asked == 0)
        #expect(h.delivered.map { $0.item.filename } == ["c.zip", "picked.zip"])
        // The exemption is used once: the page's own download of the link asks.
        h.event(34, browser: 5, id: 5, s1: link.absoluteString, s2: "c.zip")
        #expect(asked == 1)
    }

    @Test func aDownloadThatEndsWhileAskingIsDropped() throws {
        let h = try Harness()
        defer { h.remove() }
        var pending: ((Bool) -> Void)?
        h.downloads.admit = { _, decide in pending = decide }
        h.event(34, browser: 5, id: 6, s1: "https://e.com/d.zip", s2: "d.zip")
        h.event(36, browser: 5, id: 6, a: 2)
        pending?(true)
        #expect(h.fake.answers.isEmpty)
        #expect(h.delivered.isEmpty)
        #expect(h.names.isEmpty)
    }
}

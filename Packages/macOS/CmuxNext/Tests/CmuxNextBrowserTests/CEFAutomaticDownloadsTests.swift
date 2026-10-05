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
            decide(.refused)
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
        var pending: ((AutomaticDownloadGate.Outcome) -> Void)?
        h.downloads.admit = { _, decide in pending = decide }
        h.event(34, browser: 5, id: 2, s1: "https://e.com/b.zip", s2: "b.zip")
        #expect(h.fake.answers.isEmpty)
        #expect(h.delivered.isEmpty)
        pending?(.allowed)
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
            decide(.refused)
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
        var pending: ((AutomaticDownloadGate.Outcome) -> Void)?
        h.downloads.admit = { _, decide in pending = decide }
        h.event(34, browser: 5, id: 6, s1: "https://e.com/d.zip", s2: "d.zip")
        h.event(36, browser: 5, id: 6, a: 2)
        pending?(.allowed)
        #expect(h.fake.answers.isEmpty)
        #expect(h.delivered.isEmpty)
        #expect(h.names.isEmpty)
    }

    /// Fail-closed: a download no one could be asked about is cancelled and
    /// listed blocked, with the reason, and leaves no file.
    @Test func anUnansweredDownloadIsListedBlocked() throws {
        let h = try Harness()
        defer { h.remove() }
        h.downloads.admit = { _, decide in decide(.unanswered) }
        h.event(34, browser: 5, id: 8, s1: "https://e.com/e.zip", s2: "../e.zip")
        #expect(h.fake.answers.map { $0.id } == [8])
        #expect(h.fake.answers.map { $0.path } == [""])
        let item = try #require(h.delivered.first?.item)
        #expect(h.delivered.map { $0.browser } == [5])
        #expect(item.filename == "e.zip")
        #expect(item.sourceURL?.absoluteString == "https://e.com/e.zip")
        guard case .blocked(let reason) = item.status else {
            Issue.record("status \(item.status) is not blocked")
            return
        }
        #expect(!reason.isEmpty)
        #expect(h.names.isEmpty)
    }

    /// The person answered Block: the held download is cancelled and listed
    /// blocked too (a later one, refused by the remembered Block, is not).
    @Test func aDeclinedDownloadIsListedBlocked() throws {
        let h = try Harness()
        defer { h.remove() }
        h.downloads.admit = { _, decide in decide(.declined) }
        h.event(34, browser: 5, id: 9, s1: "https://e.com/f.zip", s2: "f.zip")
        #expect(h.fake.answers.map { $0.path } == [""])
        let item = try #require(h.delivered.first?.item)
        guard case .blocked(let reason) = item.status else {
            Issue.record("status \(item.status) is not blocked")
            return
        }
        #expect(!reason.isEmpty)
        h.downloads.admit = { _, decide in decide(.refused) }
        h.event(34, browser: 5, id: 10, s1: "https://e.com/g.zip", s2: "g.zip")
        #expect(h.delivered.count == 1)
    }
}

import Foundation
import Testing
@testable import CmuxNextBrowser

/// Chromium downloads through the shim (S2): the shim's events become one
/// engine-neutral `BrowserDownload` per download, every download asks cmux
/// for its path (the Downloads folder or the file the person chose), and
/// Save Link As on a Chromium tab downloads into the chosen file. The shim
/// is a fake that records what cmux asked of it.
@MainActor
@Suite struct CEFDownloadsTests {
    final class FakeShim {
        var started: [(browser: Int32, url: String)] = []
        var answers: [(id: Int32, path: String)] = []
        var controls: [(id: Int32, command: Int32)] = []
        var startSucceeds = true

        var shim: CEFDownloadShim {
            CEFDownloadShim(
                start: { [self] browser, url in started.append((browser, url)); return startSucceeds },
                answer: { [self] id, path in answers.append((id, path)) },
                control: { [self] id, command in controls.append((id, command)) }
            )
        }
    }

    final class Harness {
        let fake: FakeShim
        let downloads: CEFDownloads
        var delivered: [(browser: Int32, item: BrowserDownload)] = []
        var removed: [URL] = []
        var existing: Set<String> = []

        init() {
            let fake = FakeShim()
            self.fake = fake
            downloads = CEFDownloads { fake.shim }
            downloads.directory = { URL(filePath: "/Users/me/Downloads", directoryHint: .isDirectory) }
            downloads.exists = { [unowned self] in existing.contains($0.path(percentEncoded: false)) }
            downloads.removeReplaced = { [unowned self] in removed.append($0) }
            downloads.deliver = { [unowned self] browser, item in delivered.append((browser, item)) }
        }

        func event(_ kind: Int32, browser: Int32 = 5, id: Int32 = 42, a: Int64 = 0, b: Int64 = 0, s1: String = "", s2: String = "") {
            guard case .download(let event) = CEFShimEvent(kind: kind, browser: browser, request: id, a: a, b: b, s1: s1, s2: s2) else {
                Issue.record("kind \(kind) is not a download event")
                return
            }
            downloads.handle(event)
        }
    }

    @Test func shimEventsDecode() {
        #expect(CEFShimEvent(kind: 34, browser: 5, request: 42, a: 1200, b: 0, s1: "https://e.com/a.zip", s2: "a.zip")
            == .download(.started(id: 42, browser: 5, url: "https://e.com/a.zip", suggestedName: "a.zip", totalBytes: 1200)))
        #expect(CEFShimEvent(kind: 34, browser: 0, request: 1, a: -1, b: 0, s1: "https://e.com/x", s2: "")
            == .download(.started(id: 1, browser: 0, url: "https://e.com/x", suggestedName: "", totalBytes: nil)))
        #expect(CEFShimEvent(kind: 35, browser: 5, request: 42, a: 600, b: 1200, s1: "300", s2: "paused")
            == .download(.progress(id: 42, receivedBytes: 600, totalBytes: 1200, bytesPerSecond: 300, paused: true)))
        #expect(CEFShimEvent(kind: 36, browser: 5, request: 42, a: 3, b: 20, s1: "", s2: "")
            == .download(.done(id: 42, end: .interrupted, reason: 20, path: "")))
        #expect(CEFShimEvent(kind: 36, browser: 5, request: 42, a: 9, b: 0, s1: "", s2: "") == .unknown(kind: 36))
    }

    /// A page's download goes to the Downloads folder under its sanitized,
    /// unique name; progress and completion reach the delivered download.
    @Test func aPageDownloadLandsInTheDownloadsFolder() throws {
        let h = Harness()
        h.existing = ["/Users/me/Downloads/report.pdf"]
        h.event(34, a: 1000, s1: "https://e.com/r", s2: "../report.pdf")
        #expect(h.fake.answers.map { $0.id } == [42])
        #expect(h.fake.answers.map { $0.path } == ["/Users/me/Downloads/report (1).pdf"])
        #expect(h.removed.isEmpty)
        let item = try #require(h.delivered.first?.item)
        #expect(h.delivered.map { $0.browser } == [5])
        #expect(item.filename == "report (1).pdf")
        #expect(item.sourceURL?.absoluteString == "https://e.com/r")
        #expect(item.status == .inProgress)

        h.event(35, a: 250, b: 1000, s1: "125")
        #expect(item.fraction == 0.25)
        #expect(item.receivedBytes == 250)
        #expect(item.bytesPerSecond == 125)
        var ended: [BrowserDownload.Status] = []
        item.onFinish { ended.append($0.status) }
        h.event(36, a: 1, s1: "/Users/me/Downloads/report (1).pdf")
        #expect(item.status == .finished)
        #expect(item.fraction == 1)
        #expect(ended == [.finished])
        // A late event for a finished download changes nothing.
        h.event(36, a: 2)
        #expect(item.status == .finished)
    }

    /// Save Link As on a Chromium tab: the shim downloads the link with the
    /// tab's session, and the download goes to the exact file chosen in the
    /// save panel (which already agreed to replace it).
    @Test func saveLinkAsDownloadsIntoTheChosenFile() throws {
        let h = Harness()
        let chosen = URL(filePath: "/Users/me/Desktop/picked name.zip")
        let link = try #require(URL(string: "https://e.com/files/archive.zip"))
        #expect(h.downloads.save(link, to: chosen, browser: 9))
        #expect(h.fake.started.map { $0.browser } == [9])
        #expect(h.fake.started.map { $0.url } == ["https://e.com/files/archive.zip"])
        h.event(34, browser: 9, id: 7, s1: "https://e.com/files/archive.zip", s2: "archive.zip")
        #expect(h.fake.answers.map { $0.path } == ["/Users/me/Desktop/picked name.zip"])
        #expect(h.removed == [chosen])
        let item = try #require(h.delivered.first?.item)
        #expect(item.destination == chosen)
        #expect(item.filename == "picked name.zip")
        h.event(36, browser: 9, id: 7, a: 1, s1: chosen.path(percentEncoded: false))
        #expect(item.status == .finished)

        // The pick is used once: the next download of that link goes to Downloads.
        h.event(34, browser: 9, id: 8, s1: "https://e.com/files/archive.zip", s2: "archive.zip")
        #expect(h.fake.answers.last?.path == "/Users/me/Downloads/archive.zip")
    }

    @Test func aPickForAnotherTabDoesNotApply() throws {
        let h = Harness()
        let link = try #require(URL(string: "https://e.com/a"))
        _ = h.downloads.save(link, to: URL(filePath: "/tmp/a"), browser: 9)
        h.event(34, browser: 5, id: 1, s1: "https://e.com/a", s2: "a")
        #expect(h.fake.answers.map { $0.path } == ["/Users/me/Downloads/a"])
    }

    @Test func cancelPauseAndFailure() throws {
        let h = Harness()
        h.event(34, id: 1, s1: "https://e.com/a", s2: "a")
        let item = try #require(h.delivered.first?.item)
        item.setPaused(true)
        h.event(35, id: 1, a: 10, b: 100, s2: "paused")
        #expect(item.isPaused)
        item.setPaused(false)
        item.cancel()
        #expect(h.fake.controls.map { $0.command } == [1, 2, 0])
        #expect(h.fake.controls.allSatisfy { $0.id == 1 })
        #expect(item.status == .cancelled)
        h.event(36, id: 1, a: 2)
        #expect(item.status == .cancelled)

        h.event(34, id: 2, s1: "https://e.com/b", s2: "b")
        let failing = try #require(h.delivered.last?.item)
        h.event(36, id: 2, a: 3, b: 20)
        #expect(failing.status == .failed("interrupted (20)"))
    }

    /// Events for downloads cmux never answered (or already ended) are ignored.
    @Test func unknownDownloadsAreIgnored() {
        let h = Harness()
        h.event(35, id: 99, a: 1, b: 2)
        h.event(36, id: 99, a: 1)
        #expect(h.delivered.isEmpty)
        #expect(h.fake.answers.isEmpty)
    }

    @Test func aFailedStartForgetsThePick() throws {
        let h = Harness()
        h.fake.startSucceeds = false
        let link = try #require(URL(string: "https://e.com/a"))
        #expect(!h.downloads.save(link, to: URL(filePath: "/tmp/a"), browser: 9))
        h.event(34, browser: 9, id: 1, s1: "https://e.com/a", s2: "a")
        #expect(h.fake.answers.map { $0.path } == ["/Users/me/Downloads/a"])
    }
}

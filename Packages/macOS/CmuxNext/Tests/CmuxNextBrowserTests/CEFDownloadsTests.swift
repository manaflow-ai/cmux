import Foundation
import Testing
@testable import CmuxNextBrowser

/// Chromium downloads through the shim (S2): the shim's events become one
/// engine-neutral `BrowserDownload` per download, every download asks cmux
/// for its path (a temporary sibling of the Downloads file or of the file
/// the person chose, moved into place when it completes), and Save Link As
/// on a Chromium tab downloads into the chosen file. The shim is a fake that
/// records what cmux asked of it; the Downloads folder is a real folder.
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
        let folder: URL
        var delivered: [(browser: Int32, item: BrowserDownload)] = []

        init() throws {
            let fake = FakeShim()
            self.fake = fake
            let folder = FileManager.default.temporaryDirectory
                .appending(path: "nxdl-cef-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.folder = folder
            downloads = CEFDownloads { fake.shim }
            downloads.directory = { folder }
            downloads.reservations = BrowserDownloadReservations()
            downloads.deliver = { [unowned self] browser, item in delivered.append((browser, item)) }
        }

        func remove() { try? FileManager.default.removeItem(at: folder) }

        func file(_ name: String) -> URL { folder.appending(path: name, directoryHint: .notDirectory) }

        func read(_ url: URL) -> String? {
            (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
        }

        /// Chromium writes the answered path of download `id`.
        func chromiumWrites(_ text: String, id: Int32) throws -> String {
            let path = try #require(fake.answers.last { $0.id == id }?.path)
            try Data(text.utf8).write(to: URL(filePath: path))
            return path
        }

        var names: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []).sorted()
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

    /// A page's download is written next to its Downloads file under a
    /// temporary name and lands under its sanitized, unique name when it
    /// completes; progress and completion reach the delivered download.
    @Test func aPageDownloadLandsInTheDownloadsFolder() throws {
        let h = try Harness()
        defer { h.remove() }
        try Data("old".utf8).write(to: h.file("report.pdf"))
        h.event(34, a: 1000, s1: "https://e.com/r", s2: "../report.pdf")
        #expect(h.fake.answers.map { $0.id } == [42])
        let answered = try #require(h.fake.answers.first?.path)
        #expect(answered != h.file("report (1).pdf").path(percentEncoded: false))
        #expect(URL(filePath: answered).deletingLastPathComponent().standardizedFileURL == h.folder.standardizedFileURL)
        let item = try #require(h.delivered.first?.item)
        #expect(h.delivered.map { $0.browser } == [5])
        #expect(item.filename == "report (1).pdf")
        #expect(item.destination == h.file("report (1).pdf"))
        #expect(item.sourceURL?.absoluteString == "https://e.com/r")
        #expect(item.status == .inProgress)

        h.event(35, a: 250, b: 1000, s1: "125")
        #expect(item.fraction == 0.25)
        #expect(item.receivedBytes == 250)
        #expect(item.bytesPerSecond == 125)
        var ended: [BrowserDownload.Status] = []
        item.onFinish { ended.append($0.status) }
        let path = try h.chromiumWrites("pdf", id: 42)
        h.event(36, a: 1, s1: path)
        #expect(item.status == .finished)
        #expect(item.fraction == 1)
        #expect(ended == [.finished])
        #expect(h.read(h.file("report (1).pdf")) == "pdf")
        #expect(h.read(h.file("report.pdf")) == "old")
        #expect(h.names == ["report (1).pdf", "report.pdf"])
        // A late event for a finished download changes nothing.
        h.event(36, a: 2)
        #expect(item.status == .finished)
    }

    /// P2-2: two same-name downloads at once land in two files, both
    /// quarantined.
    @Test func twoSimultaneousSameNameDownloadsGetTwoFiles() throws {
        let h = try Harness()
        defer { h.remove() }
        h.event(34, id: 1, s1: "https://e.com/a", s2: "same.txt")
        h.event(34, id: 2, s1: "https://e.com/b", s2: "same.txt")
        #expect(Set(h.fake.answers.map { $0.path }).count == 2)
        let first = try h.chromiumWrites("one", id: 1)
        let second = try h.chromiumWrites("two", id: 2)
        h.event(36, id: 2, a: 1, s1: second)
        h.event(36, id: 1, a: 1, s1: first)
        #expect(h.delivered.map { $0.item.status } == [.finished, .finished])
        #expect(h.names == ["same (1).txt", "same.txt"])
        #expect(h.read(h.file("same.txt")) == "one")
        #expect(h.read(h.file("same (1).txt")) == "two")
        for name in h.names {
            #expect(getxattr(h.file(name).path(percentEncoded: false), "com.apple.quarantine", nil, 0, 0, 0) > 0)
        }
    }

    /// Save Link As on a Chromium tab: the shim downloads the link with the
    /// tab's session, and the download replaces the exact file chosen in
    /// the save panel only once it completes.
    @Test func saveLinkAsDownloadsIntoTheChosenFile() throws {
        let h = try Harness()
        defer { h.remove() }
        let chosen = h.file("picked name.zip")
        try Data("old".utf8).write(to: chosen)
        let link = try #require(URL(string: "https://e.com/files/archive.zip"))
        #expect(h.downloads.save(link, to: chosen, browser: 9))
        #expect(h.fake.started.map { $0.browser } == [9])
        #expect(h.fake.started.map { $0.url } == ["https://e.com/files/archive.zip"])
        h.event(34, browser: 9, id: 7, s1: "https://e.com/files/archive.zip", s2: "archive.zip")
        #expect(h.fake.answers.first?.path != chosen.path(percentEncoded: false))
        #expect(h.read(chosen) == "old")
        let item = try #require(h.delivered.first?.item)
        #expect(item.destination == chosen)
        #expect(item.filename == "picked name.zip")
        let path = try h.chromiumWrites("new", id: 7)
        h.event(36, browser: 9, id: 7, a: 1, s1: path)
        #expect(item.status == .finished)
        #expect(h.read(chosen) == "new")

        // The pick is used once: the next download of that link goes to Downloads.
        h.event(34, browser: 9, id: 8, s1: "https://e.com/files/archive.zip", s2: "archive.zip")
        #expect(h.delivered.last?.item.destination == h.file("archive.zip"))
    }

    /// P2-3: a Save As download that fails keeps the file it would replace.
    @Test func aFailedSaveAsKeepsTheOldFile() throws {
        let h = try Harness()
        defer { h.remove() }
        let chosen = h.file("keep.zip")
        try Data("old".utf8).write(to: chosen)
        let link = try #require(URL(string: "https://e.com/k.zip"))
        #expect(h.downloads.save(link, to: chosen, browser: 9))
        h.event(34, browser: 9, id: 3, s1: "https://e.com/k.zip", s2: "k.zip")
        _ = try h.chromiumWrites("partial", id: 3)
        h.event(36, browser: 9, id: 3, a: 3, b: 20)
        #expect(h.delivered.first?.item.status == .failed("interrupted (20)"))
        #expect(h.read(chosen) == "old")
        #expect(h.names == ["keep.zip"])
    }

    @Test func aPickForAnotherTabDoesNotApply() throws {
        let h = try Harness()
        defer { h.remove() }
        let link = try #require(URL(string: "https://e.com/a"))
        _ = h.downloads.save(link, to: URL(filePath: "/tmp/a"), browser: 9)
        h.event(34, browser: 5, id: 1, s1: "https://e.com/a", s2: "a")
        #expect(h.delivered.first?.item.destination == h.file("a"))
    }

    @Test func cancelPauseAndFailure() throws {
        let h = try Harness()
        defer { h.remove() }
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
        _ = try h.chromiumWrites("part", id: 2)
        h.event(36, id: 2, a: 3, b: 20)
        #expect(failing.status == .failed("interrupted (20)"))
        // A failed or cancelled download leaves no file behind.
        #expect(h.names.isEmpty)
    }

    /// P3 (8): only web downloads start; a file: URL (or any other scheme)
    /// never reaches the shim.
    @Test func onlyWebSchemesDownload() throws {
        let h = try Harness()
        defer { h.remove() }
        #expect(!h.downloads.download("file:///etc/passwd", browser: 5))
        #expect(!h.downloads.download("javascript:alert(1)", browser: 5))
        #expect(!h.downloads.download("chrome://settings", browser: 5))
        #expect(!h.downloads.save(URL(filePath: "/etc/passwd"), to: h.file("p"), browser: 5))
        #expect(h.fake.started.isEmpty)
        #expect(h.downloads.download("https://e.com/a", browser: 5))
        #expect(h.downloads.download("HTTP://e.com/a", browser: 5))
        #expect(h.downloads.download("data:text/plain,x", browser: 5))
        #expect(h.downloads.download("blob:https://e.com/1", browser: 5))
        #expect(h.fake.started.count == 4)
    }

    /// Events for downloads cmux never answered (or already ended) are ignored.
    @Test func unknownDownloadsAreIgnored() throws {
        let h = try Harness()
        defer { h.remove() }
        h.event(35, id: 99, a: 1, b: 2)
        h.event(36, id: 99, a: 1)
        #expect(h.delivered.isEmpty)
        #expect(h.fake.answers.isEmpty)
    }

    @Test func aFailedStartForgetsThePick() throws {
        let h = try Harness()
        defer { h.remove() }
        h.fake.startSucceeds = false
        let link = try #require(URL(string: "https://e.com/a"))
        #expect(!h.downloads.save(link, to: URL(filePath: "/tmp/a"), browser: 9))
        h.event(34, browser: 9, id: 1, s1: "https://e.com/a", s2: "a")
        #expect(h.delivered.first?.item.destination == h.file("a"))
    }

    /// P3 (2): the shim sends the popup's target URL with the AFTER_CREATED
    /// of its tab, in the same record as its disposition and gesture.
    @Test func aPopupTabCarriesItsTargetURL() {
        let event = CEFShimEvent(kind: 2, browser: 12, request: 0, a: 0, b: (Int64(7) << 32) | (1 << 16) | 3,
                                 s1: "", s2: "https://e.com/target")
        guard case .afterCreated(_, _, _, let created) = event else {
            Issue.record("not AFTER_CREATED")
            return
        }
        #expect(created.url == "https://e.com/target")
        #expect(created.disposition == .newForegroundTab)
        #expect(created.userGesture)
        #expect(CEFCreatedBy(packed: Int64(7) << 32, features: "", url: "").url == nil)
    }
}

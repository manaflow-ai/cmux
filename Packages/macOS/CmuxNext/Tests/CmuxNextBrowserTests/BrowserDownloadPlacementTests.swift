import Foundation
import Testing
@testable import CmuxNextBrowser

/// Where a download of either engine is written (`BrowserDownloadPlacement`):
/// a temporary sibling while it runs, moved into place only when it
/// completes. A Downloads name is reserved while its download runs and is
/// created exclusively, so two same-name downloads get two files and a file
/// that appeared meanwhile (or a dangling symlink) is never written over; a
/// confirmed Save As file is replaced only by a complete download. Every test
/// runs in its own real folder.
@MainActor
@Suite struct BrowserDownloadPlacementTests {
    struct Folder {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appending(path: "nxdl-placement-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: url) }

        @discardableResult
        func write(_ name: String, _ text: String) throws -> URL {
            let file = url.appending(path: name, directoryHint: .notDirectory)
            try Data(text.utf8).write(to: file)
            return file
        }

        func read(_ file: URL) -> String? {
            (try? Data(contentsOf: file)).map { String(decoding: $0, as: UTF8.self) }
        }

        var names: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []).sorted()
        }
    }

    private func place(_ name: String, in folder: Folder, chosen: URL? = nil,
                       reservations: BrowserDownloadReservations) throws -> BrowserDownloadPlacement {
        try #require(BrowserDownloadPolicy.place(chosen: chosen, suggestedFilename: name, directory: folder.url,
                                                 reservations: reservations))
    }

    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path(percentEncoded: false), &info) == 0
    }

    /// P2-2: two downloads of the same name at once get two names and two
    /// temporary files, and both land.
    @Test func twoSameNameDownloadsGetTwoFiles() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let reservations = BrowserDownloadReservations()
        let a = try place("a.txt", in: folder, reservations: reservations)
        let b = try place("a.txt", in: folder, reservations: reservations)
        #expect(a.finalURL.lastPathComponent == "a.txt")
        #expect(b.finalURL.lastPathComponent == "a (1).txt")
        #expect(a.temporaryURL != a.finalURL)
        #expect(b.temporaryURL != b.finalURL)
        #expect(a.temporaryURL != b.temporaryURL)
        #expect(a.temporaryURL.deletingLastPathComponent().standardizedFileURL == folder.url.standardizedFileURL)
        try Data("A".utf8).write(to: a.temporaryURL)
        try Data("B".utf8).write(to: b.temporaryURL)
        #expect(try b.finish() == b.finalURL)
        #expect(try a.finish() == a.finalURL)
        #expect(folder.read(a.finalURL) == "A")
        #expect(folder.read(b.finalURL) == "B")
        #expect(folder.names == ["a (1).txt", "a.txt"])
    }

    /// A name is reserved only while its download runs.
    @Test func aDiscardedDownloadFreesItsName() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let reservations = BrowserDownloadReservations()
        let first = try place("c.txt", in: folder, reservations: reservations)
        first.discard()
        let second = try place("c.txt", in: folder, reservations: reservations)
        #expect(second.finalURL.lastPathComponent == "c.txt")
        second.discard()
        #expect(folder.names.isEmpty)
    }

    /// P2-3: Save As never touches the chosen file until the download
    /// completes; a failed one keeps the old file.
    @Test func aFailedSaveAsKeepsTheOldFile() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let reservations = BrowserDownloadReservations()
        let chosen = try folder.write("keep.txt", "old")
        let failing = try place("ignored.bin", in: folder, chosen: chosen, reservations: reservations)
        #expect(failing.finalURL == chosen)
        #expect(failing.temporaryURL != chosen)
        #expect(folder.read(chosen) == "old")
        try Data("partial".utf8).write(to: failing.temporaryURL)
        failing.discard()
        #expect(folder.read(chosen) == "old")
        #expect(!exists(failing.temporaryURL))

        let complete = try place("ignored.bin", in: folder, chosen: chosen, reservations: reservations)
        try Data("new".utf8).write(to: complete.temporaryURL)
        #expect(try complete.finish() == chosen)
        #expect(folder.read(chosen) == "new")
        #expect(folder.names == ["keep.txt"])
    }

    /// A file that appeared under the reserved name while the download ran
    /// is never overwritten: the download takes the next free name.
    @Test func aFileCreatedMeanwhileIsNeverOverwritten() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let placement = try place("a.txt", in: folder, reservations: BrowserDownloadReservations())
        try Data("mine".utf8).write(to: placement.temporaryURL)
        let theirs = try folder.write("a.txt", "theirs")
        let landed = try placement.finish()
        #expect(landed.lastPathComponent == "a (1).txt")
        #expect(folder.read(theirs) == "theirs")
        #expect(folder.read(landed) == "mine")
    }

    /// A dangling symlink in Downloads counts as taken (lstat): nothing is
    /// ever written through it.
    @Test func aDanglingSymlinkIsNeverWrittenThrough() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let target = folder.url.appending(path: "outside-target")
        try FileManager.default.createSymbolicLink(at: folder.url.appending(path: "a.txt"), withDestinationURL: target)
        #expect(DownloadDestination.uniqueURL(in: folder.url, suggestedFilename: "a.txt")?.lastPathComponent == "a (1).txt")
        let placement = try place("a.txt", in: folder, reservations: BrowserDownloadReservations())
        #expect(placement.finalURL.lastPathComponent == "a (1).txt")
        try Data("x".utf8).write(to: placement.temporaryURL)
        _ = try placement.finish()
        #expect(!exists(target))
    }

    /// Names are capped at 255 bytes and keep their extension, numbered or
    /// not; the temporary name fits too.
    @Test func longNamesKeepTheirExtension() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let long = String(repeating: "é", count: 300) + ".pdf"
        let name = try #require(DownloadDestination.uniqueURL(in: folder.url, suggestedFilename: long) { _ in false })
        #expect(name.lastPathComponent.utf8.count <= 255)
        #expect(name.lastPathComponent.hasSuffix("é.pdf"))
        let numbered = try #require(DownloadDestination.uniqueURL(in: folder.url, suggestedFilename: long) {
            $0.lastPathComponent == name.lastPathComponent
        })
        #expect(numbered.lastPathComponent.utf8.count <= 255)
        #expect(numbered.lastPathComponent.hasSuffix(" (1).pdf"))
        let placement = try place(long, in: folder, reservations: BrowserDownloadReservations())
        #expect(placement.temporaryURL.lastPathComponent.utf8.count + ".crdownload".utf8.count <= 255)
        try Data("x".utf8).write(to: placement.temporaryURL)
        #expect(try placement.finish().lastPathComponent == name.lastPathComponent)
    }

    /// After the collision limit there is no name: the download fails
    /// instead of overwriting the last candidate.
    @Test func theCollisionLimitFailsInsteadOfOverwriting() {
        let directory = URL(filePath: "/Users/me/Downloads", directoryHint: .isDirectory)
        #expect(DownloadDestination.uniqueURL(in: directory, suggestedFilename: "a.txt") { _ in true } == nil)
        #expect(BrowserDownloadPolicy.destination(chosen: nil, suggestedFilename: "a.txt", directory: directory) { _ in true } == nil)
    }

    /// Both engines end a download in `BrowserDownload.complete`: a finished
    /// one moves into place and is quarantined there; a failed or cancelled
    /// one leaves no file.
    @Test func aDownloadEndsThroughItsPlacement() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let reservations = BrowserDownloadReservations()
        let done = try place("r.zip", in: folder, reservations: reservations)
        let item = BrowserDownload(sourceURL: URL(string: "https://e.com/r.zip"), filename: "r.zip")
        item.placement = done
        try Data("zip".utf8).write(to: done.temporaryURL)
        item.complete(.finished)
        #expect(item.status == .finished)
        #expect(item.destination == done.finalURL)
        #expect(folder.read(done.finalURL) == "zip")
        #expect(!exists(done.temporaryURL))
        #expect(getxattr(done.finalURL.path(percentEncoded: false), "com.apple.quarantine", nil, 0, 0, 0) > 0)

        for end in [BrowserDownload.Status.failed("x"), .cancelled] {
            let placement = try place("f.zip", in: folder, reservations: reservations)
            let failing = BrowserDownload(sourceURL: nil, filename: "f.zip")
            failing.placement = placement
            try Data("part".utf8).write(to: placement.temporaryURL)
            failing.complete(end)
            #expect(!exists(placement.temporaryURL))
            #expect(!exists(placement.finalURL))
        }
        #expect(folder.names == ["r.zip"])
    }
}

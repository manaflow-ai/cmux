import Foundation
import Testing
@testable import CmuxNextBrowser

/// The record of the temporary `.cmuxdownload` files cmux writes
/// (`BrowserDownloadTempFiles`): a placement adds its temporary file when it
/// starts and removes it when it lands or is discarded; the next launch
/// deletes only the recorded leftovers that are still regular
/// `.cmuxdownload` files. Every test uses a real folder and a real record
/// file, and a second instance stands for the next launch.
@MainActor
@Suite struct BrowserDownloadTempFilesTests {
    struct Folder {
        let url: URL
        var record: URL { url.appending(path: "record", directoryHint: .isDirectory).appending(path: "temp-files.json") }

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appending(path: "nxdl-temp-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: url) }

        @discardableResult
        func write(_ name: String, _ text: String = "x") throws -> URL {
            let file = url.appending(path: name, directoryHint: .notDirectory)
            try Data(text.utf8).write(to: file)
            return file
        }

        /// The paths in the record file (empty when there is no file).
        func recorded() throws -> [String] {
            guard FileManager.default.fileExists(atPath: record.path(percentEncoded: false)) else { return [] }
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: record))
            return (object as? [String: Any])?["paths"] as? [String] ?? []
        }

        func writeRecord(_ paths: [String]) throws {
            try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["paths": paths]).write(to: record)
        }
    }

    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path(percentEncoded: false), &info) == 0
    }

    private func place(_ name: String, in folder: Folder, tempFiles: BrowserDownloadTempFiles) throws -> BrowserDownloadPlacement {
        try #require(BrowserDownloadPolicy.place(chosen: nil, suggestedFilename: name, directory: folder.url,
                                                 reservations: BrowserDownloadReservations(tempFiles: tempFiles)))
    }

    /// A running download's temporary file is in the record file; landing
    /// or discarding takes it out again.
    @Test func aRunningDownloadIsRecordedUntilItEnds() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let tempFiles = BrowserDownloadTempFiles(recordURL: folder.record)
        let done = try place("a.zip", in: folder, tempFiles: tempFiles)
        let dropped = try place("b.zip", in: folder, tempFiles: tempFiles)
        await tempFiles.idle()
        #expect(try Set(folder.recorded()) == [done.temporaryURL.path(percentEncoded: false),
                                               dropped.temporaryURL.path(percentEncoded: false)])
        try Data("zip".utf8).write(to: done.temporaryURL)
        _ = try done.finish()
        dropped.discard()
        await tempFiles.idle()
        #expect(try folder.recorded().isEmpty)
    }

    /// A run that ended while downloading (a crash) left its temporary
    /// file: the next launch deletes it. An unrecorded `.cmuxdownload` file
    /// in the same folder (not cmux's, or from a run with no record) stays.
    @Test func theNextLaunchDeletesOnlyRecordedLeftovers() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let lastRun = BrowserDownloadTempFiles(recordURL: folder.record)
        let running = try place("a.zip", in: folder, tempFiles: lastRun)
        try Data("part".utf8).write(to: running.temporaryURL)
        await lastRun.idle()
        let unrecorded = try folder.write("other.1234abcd.cmuxdownload")

        let nextLaunch = BrowserDownloadTempFiles(recordURL: folder.record)
        nextLaunch.cleanUpLeftovers()
        await nextLaunch.idle()
        #expect(!exists(running.temporaryURL))
        #expect(exists(unrecorded))
        #expect(try folder.recorded().isEmpty)
    }

    /// Chromium writes `<temporary>.crdownload` while it runs; a leftover
    /// of that is deleted with its recorded temporary file.
    @Test func aChromiumPartialOfARecordedFileIsDeleted() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let lastRun = BrowserDownloadTempFiles(recordURL: folder.record)
        let running = try place("a.zip", in: folder, tempFiles: lastRun)
        let partial = running.temporaryURL.appendingPathExtension("crdownload")
        try Data("part".utf8).write(to: partial)
        await lastRun.idle()

        let nextLaunch = BrowserDownloadTempFiles(recordURL: folder.record)
        nextLaunch.cleanUpLeftovers()
        await nextLaunch.idle()
        #expect(!exists(partial))
    }

    /// A recorded path that is now a symlink (even to a `.cmuxdownload`
    /// file) or a file whose name does not end in `.cmuxdownload` is never
    /// deleted, and neither is a symlink's target.
    @Test func aRecordedSymlinkOrOtherNameStays() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let target = try folder.write("target.abcd1234.cmuxdownload", "keep")
        let link = folder.url.appending(path: "link.abcd1234.cmuxdownload")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let other = try folder.write("notes.txt", "keep")
        let directory = folder.url.appending(path: "dir.abcd1234.cmuxdownload", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try folder.writeRecord([link, other, directory].map { $0.path(percentEncoded: false) } + ["relative.cmuxdownload"])

        let nextLaunch = BrowserDownloadTempFiles(recordURL: folder.record)
        nextLaunch.cleanUpLeftovers()
        await nextLaunch.idle()
        #expect(exists(link))
        #expect(exists(target))
        #expect(exists(other))
        #expect(exists(directory))
        #expect(try folder.recorded().isEmpty)
    }

    /// A download that starts before the launch cleanup ran keeps the
    /// earlier leftovers in the record, so the cleanup still finds them,
    /// and the cleanup never touches the new running download.
    @Test func aDownloadBeforeTheCleanupKeepsTheLeftovers() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let lastRun = BrowserDownloadTempFiles(recordURL: folder.record)
        let old = try place("old.zip", in: folder, tempFiles: lastRun)
        try Data("part".utf8).write(to: old.temporaryURL)
        await lastRun.idle()

        let nextLaunch = BrowserDownloadTempFiles(recordURL: folder.record)
        let fresh = try place("new.zip", in: folder, tempFiles: nextLaunch)
        try Data("part".utf8).write(to: fresh.temporaryURL)
        await nextLaunch.idle()
        nextLaunch.cleanUpLeftovers()
        await nextLaunch.idle()
        #expect(!exists(old.temporaryURL))
        #expect(exists(fresh.temporaryURL))
        #expect(try folder.recorded() == [fresh.temporaryURL.path(percentEncoded: false)])
    }
}

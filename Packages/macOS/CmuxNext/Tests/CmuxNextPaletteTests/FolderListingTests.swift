@testable import CmuxNextPalette
import Foundation
import Testing

/// One folder level read from disk (R89): folders first in Finder order,
/// git repositories marked, the mode's files, bounded pages, and the
/// failures the picker shows inline.
@Suite struct FolderListingTests {
    static func folder(_ layout: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picker-listing-\(UUID().uuidString)")
        for path in layout {
            let url = root.appendingPathComponent(path)
            if path.hasSuffix("/") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("x".utf8).write(to: url)
            }
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func foldersFirstInFinderOrderThenTheModesFiles() throws {
        let root = try Self.folder(["b.md", "A.md", "z.swift", "file10/", "file9/", "repo/.git/", ".hidden/", ".env"])
        defer { try? FileManager.default.removeItem(at: root) }
        let listing = FolderListing.readNow(root, mode: .file(.markdown), limit: 100)
        #expect(listing.failure == nil)
        #expect(listing.entries.map(\.name) == ["file9", "file10", "repo", "A.md", "b.md", ".hidden"])
        #expect(listing.entries.first { $0.name == "repo" }?.isGitRepository == true)
        #expect(listing.entries.first { $0.name == "file9" }?.isGitRepository == false)
        let folders = FolderListing.readNow(root, mode: .folder, limit: 100)
        #expect(folders.entries.allSatisfy { $0.isDirectory })
    }

    @Test func aLinkToAFolderIsAFolder() throws {
        let root = try Self.folder(["real/"])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("real"))
        let names = FolderListing.readNow(root, mode: .folder, limit: 10).entries.map(\.name)
        #expect(names == ["link", "real"])
    }

    @Test func pagesAreBoundedAndCountTheRest() throws {
        let root = try Self.folder((0..<30).map { "f\($0).txt" } + ["d/"])
        defer { try? FileManager.default.removeItem(at: root) }
        let listing = FolderListing.readNow(root, mode: .file(.any), limit: 10)
        #expect(listing.entries.count == 10)
        #expect(listing.entries.first?.name == "d")
        #expect(listing.remaining == 21)
        let scanned = FolderListing.readNow(root, mode: .file(.any), limit: 100, scanLimit: 5)
        #expect(scanned.stoppedEarly)
        #expect(scanned.entries.count == 5)
    }

    @Test func failuresAreTyped() throws {
        let missing = FolderListing.readNow(URL(fileURLWithPath: "/nope-\(UUID().uuidString)"), mode: .folder, limit: 10)
        #expect(missing.failure == .notFound)
        let root = try Self.folder(["locked/inner/"])
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("locked").path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.appendingPathComponent("locked").path)
        let denied = FolderListing.readNow(root.appendingPathComponent("locked"), mode: .folder, limit: 10)
        #expect(denied.failure == .permissionDenied)
    }

    @Test func readRunsOffTheMainActor() async throws {
        let root = try Self.folder(["a/"])
        defer { try? FileManager.default.removeItem(at: root) }
        let listing = await FolderListing.read(root, mode: .folder, limit: 10)
        #expect(listing.entries.map(\.name) == ["a"])
    }
}

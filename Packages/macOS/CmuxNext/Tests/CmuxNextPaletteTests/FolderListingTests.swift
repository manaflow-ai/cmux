import Foundation
import Testing
@testable import CmuxNextPalette

/// The picker's `readdir` listing against a real temp folder: each name copied out of its record (a
/// non-ASCII one included), folders and links to them told from files, hidden entries after the
/// visible ones, git repositories found.
struct FolderListingTests {
    @Test func listsFoldersLinksAndFilesFromTheirRecords() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("picker-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: root.appendingPathComponent("repo/.git"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("plain"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("plain"))
        try Data("x".utf8).write(to: root.appendingPathComponent("notes-é.txt"))
        defer { try? fm.removeItem(at: root) }

        let folders = FolderListing.readNow(root, mode: .folder, limit: 10)
        #expect(folders.failure == nil)
        #expect(folders.entries.map(\.name) == ["link", "plain", "repo", ".hidden"])
        let allFolders = folders.entries.allSatisfy(\.isDirectory)
        #expect(allFolders)
        #expect(folders.entries.first { $0.name == "repo" }?.isGitRepository == true)
        #expect(folders.entries.first { $0.name == "plain" }?.isGitRepository == false)

        let files = FolderListing.readNow(root, mode: .file(.any), limit: 10)
        #expect(files.entries.contains { $0.name == "notes-é.txt" && !$0.isDirectory })
    }

    @Test func aMissingFolderSaysNotFound() {
        let listing = FolderListing.readNow(URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"), mode: .folder, limit: 10)
        #expect(listing.failure == .notFound)
        #expect(listing.entries.isEmpty)
    }
}

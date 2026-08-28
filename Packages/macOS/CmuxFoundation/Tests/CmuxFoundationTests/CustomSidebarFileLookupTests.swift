import Foundation
import Testing

@testable import CmuxFoundation

/// Exact-name resolution, which is the property that makes a sidebar authored on one Mac work on the
/// next.
///
/// APFS is case-insensitive by default, so a plain `fileExists` for `board.json` finds a file
/// actually named `board.JSON` — which every other part of the pipeline then refuses, leaving a
/// sidebar that resolves and renders nothing. The lookup exists to answer the stricter question, and
/// these tests pin the answer independently of how it is obtained.
@Suite("Custom sidebar file lookup")
struct CustomSidebarFileLookupTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sidebar-lookup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a file is found only under the exact name it has on disk")
    func exactNameOnly() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "x".write(
            to: directory.appendingPathComponent("board.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "x".write(
            to: directory.appendingPathComponent("Mixed.SWIFT"),
            atomically: true,
            encoding: .utf8
        )
        let lookup = CustomSidebarFileLookup()

        #expect(lookup.exists(directory.appendingPathComponent("board.swift")))
        #expect(!lookup.exists(directory.appendingPathComponent("BOARD.swift")))
        #expect(!lookup.exists(directory.appendingPathComponent("board.SWIFT")))
        // The reverse direction: a file stored under a folded name is not found under the canonical
        // one either, so discovery and resolution agree about which files are real.
        #expect(lookup.exists(directory.appendingPathComponent("Mixed.SWIFT")))
        #expect(!lookup.exists(directory.appendingPathComponent("mixed.swift")))
    }

    @Test("a directory is never a sidebar source, even under an exactly matching name")
    func directoriesAreRefused() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("board.swift"),
            withIntermediateDirectories: true
        )
        let lookup = CustomSidebarFileLookup()

        #expect(!lookup.exists(directory.appendingPathComponent("board.swift")))
    }

    /// A sidebar symlinked in from a dotfiles repo is a real setup, and it resolved before, so it
    /// has to keep resolving. A link to a directory or to nothing does not.
    @Test("a symlink to a file resolves; a symlink to a directory or to nothing does not")
    func symlinkBehaviour() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("real.swift")
        try "x".write(to: target, atomically: true, encoding: .utf8)
        let targetDirectory = directory.appendingPathComponent("realdir")
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("linkToFile.swift"),
            withDestinationURL: target
        )
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("linkToDir.swift"),
            withDestinationURL: targetDirectory
        )
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("dangling.swift"),
            withDestinationURL: directory.appendingPathComponent("nothing")
        )
        let lookup = CustomSidebarFileLookup()

        #expect(lookup.exists(directory.appendingPathComponent("linkToFile.swift")))
        #expect(!lookup.exists(directory.appendingPathComponent("linkToDir.swift")))
        #expect(!lookup.exists(directory.appendingPathComponent("dangling.swift")))
        // The link's own name is still matched exactly.
        #expect(!lookup.exists(directory.appendingPathComponent("LinkToFile.swift")))
    }

    /// The lookup is asked the same question repeatedly about a live directory — a sidebar surface
    /// re-resolves on every `cmux sidebar reload` — so it has to answer about the filesystem as it is
    /// now, not as it was the first time this URL was asked about.
    ///
    /// `URL` memoises resource values it has already fetched. A caller that holds one candidate URL
    /// and probes it across a rename therefore gets the *old* spelling back, and a sidebar the
    /// classifier will now refuse keeps resolving as though nothing changed. The rename here is
    /// case-only because that is exactly the case this type exists to catch, and the one a
    /// case-insensitive volume will not catch for it.
    @Test("a retained URL re-probed after a case-only rename reports the new spelling")
    func retainedURLDoesNotServeAStaleName() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("board.swift")
        try "x".write(to: original, atomically: true, encoding: .utf8)
        let lookup = CustomSidebarFileLookup()

        // One retained URL, probed before and after the rename, as a live surface does.
        let candidate = directory.appendingPathComponent("board.swift", isDirectory: false)
        #expect(lookup.exists(candidate))

        try FileManager.default.moveItem(
            at: original,
            to: directory.appendingPathComponent("BOARD.swift")
        )
        // The rename really took, independently of anything the lookup believes.
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["BOARD.swift"]
        )

        #expect(!lookup.exists(candidate))
        // And the other direction now resolves, on a URL that has never been probed before.
        #expect(lookup.exists(directory.appendingPathComponent("BOARD.swift", isDirectory: false)))
    }

    @Test("a missing file, and a missing directory, resolve to nothing")
    func missingPaths() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lookup = CustomSidebarFileLookup()

        #expect(!lookup.exists(directory.appendingPathComponent("board.swift")))
        #expect(!lookup.exists(
            URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/board.swift")
        ))
    }

    /// A `FileManager` that records every directory enumeration asked of it.
    ///
    /// Enumeration is the operation whose cost scales with the directory, so counting the calls is
    /// the property itself rather than a proxy for it. Recorded rather than refused, so a failure
    /// says how many times it happened instead of surfacing as an unrelated error.
    private final class EnumerationCountingFileManager: FileManager, @unchecked Sendable {
        private let lock = NSLock()
        private var _enumerationCount = 0

        var enumerationCount: Int { lock.withLock { _enumerationCount } }

        private func recordEnumeration() {
            lock.withLock { _enumerationCount += 1 }
        }

        override func contentsOfDirectory(atPath path: String) throws -> [String] {
            recordEnumeration()
            return try super.contentsOfDirectory(atPath: path)
        }

        override func contentsOfDirectory(
            at url: URL,
            includingPropertiesForKeys keys: [URLResourceKey]?,
            options mask: FileManager.DirectoryEnumerationOptions = []
        ) throws -> [URL] {
            recordEnumeration()
            return try super.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: mask
            )
        }

        override func enumerator(atPath path: String) -> FileManager.DirectoryEnumerator? {
            recordEnumeration()
            return super.enumerator(atPath: path)
        }
    }

    /// Resolution probes one candidate per recognised extension, on the sidebar's render path, so
    /// its cost must not scale with how many sidebars the user has authored.
    ///
    /// Stated as the operation rather than as a duration: listing the enclosing directory to learn
    /// one entry's real name is the shape whose cost is proportional to the directory, and reading
    /// the entry's own `nameKey` is the shape that is not. Asserting that no enumeration happens
    /// pins the algorithm directly, and does it identically on a fast machine and a loaded CI box —
    /// which a measured comparison against a 2000-entry directory could not.
    @Test("a lookup answers from the entry itself, never by listing the directory")
    func lookupDoesNotEnumerateTheDirectory() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "x".write(
            to: directory.appendingPathComponent("board.swift"),
            atomically: true,
            encoding: .utf8
        )
        let fileManager = EnumerationCountingFileManager()
        let lookup = CustomSidebarFileLookup(fileManager: fileManager)

        // Every answer the lookup can give: a hit, a case-only miss, an absent file, and a
        // directory. None of them is a reason to list the enclosing directory.
        #expect(lookup.exists(directory.appendingPathComponent("board.swift")))
        #expect(!lookup.exists(directory.appendingPathComponent("BOARD.swift")))
        #expect(!lookup.exists(directory.appendingPathComponent("absent.swift")))
        #expect(!lookup.exists(directory))

        #expect(
            fileManager.enumerationCount == 0,
            "the lookup listed the directory \(fileManager.enumerationCount) time(s)"
        )
    }
}

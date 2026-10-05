@testable import CmuxNextApp
import Foundation
import Testing

/// The file pages' disk rules (diff-host S6, S7): the page gets the bytes decoded as UTF-8 with
/// nothing removed, and a save writes back exactly the bytes the page sent, atomically, only on
/// the page's base hash, and never when nothing changed.
@Suite struct FileDocumentTests {
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "cmux-file-pages-\(UUID().uuidString)", directoryHint: .isDirectory)
        try makeDirectory(url)
        return url.resolvingSymlinksInPath()
    }

    /// Creates `url` and any missing parents with mode 0755 set explicitly. The process umask is
    /// shared by every test in the run: ControlSocketServer sets it to 0177 around its bind, and a
    /// folder made in that window would have no search bit (mode 0600), so files could not be
    /// created in it (the parallel run's "You don't have permission to save the file").
    static func makeDirectory(_ url: URL) throws {
        var missing: [URL] = []
        var candidate = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: candidate.path) {
            missing.append(candidate)
            candidate = candidate.deletingLastPathComponent()
        }
        for folder in missing.reversed() {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        }
    }

    static func write(_ bytes: [UInt8], _ name: String, in folder: URL) throws -> URL {
        let url = folder.appending(path: name)
        try Data(bytes).write(to: url)
        return url
    }

    static func inode(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    @Test func theTextKeepsTheBOMEveryLineEndingAndAMissingFinalNewline() throws {
        let folder = try Self.folder()
        let bytes: [UInt8] = [0xEF, 0xBB, 0xBF] + Array("a\r\nb\nc\rd".utf8)
        let url = try Self.write(bytes, "mixed.ts", in: folder)
        let file = try FileDocument.read(url, inWorkspace: true)
        #expect(file.text == "\u{FEFF}a\r\nb\nc\rd")
        #expect(Data(file.text.utf8) == Data(bytes))
        #expect(file.size == bytes.count)
        #expect(file.hash == FileDocument.hash(Data(bytes)))
        #expect(file.readOnlyReason == nil)
    }

    @Test func savingTheSameTextWritesNothingAndAnEditWritesExactlyItsBytes() throws {
        let folder = try Self.folder()
        let original: [UInt8] = [0xEF, 0xBB, 0xBF] + Array("one\r\ntwo".utf8)
        let url = try Self.write(original, "a.md", in: folder)
        let file = try FileDocument.read(url, inWorkspace: true)
        let before = Self.inode(url)
        let same = try FileDocument.save(file.text, to: url, baseHash: file.hash, inWorkspace: true)
        #expect(same == FileSaveResult(hash: file.hash, written: false))
        #expect(Self.inode(url) == before, "an unchanged save never touches the file")
        let edited = "\u{FEFF}one\r\ntwo\r\nthree"
        let saved = try FileDocument.save(edited, to: url, baseHash: file.hash, inWorkspace: true)
        #expect(saved.written)
        #expect(try Data(contentsOf: url) == Data(edited.utf8))
        #expect(saved.hash == FileDocument.hash(Data(edited.utf8)))
    }

    @Test func aStaleBaseHashIsAConflictWithTheFileAsItIsNow() throws {
        let folder = try Self.folder()
        let url = try Self.write(Array("v1".utf8), "a.txt", in: folder)
        let base = try FileDocument.read(url, inWorkspace: true).hash
        try Data("v2 from elsewhere".utf8).write(to: url)
        #expect(throws: FileSaveFailure.conflict(hash: FileDocument.hash(Data("v2 from elsewhere".utf8)), text: "v2 from elsewhere")) {
            try FileDocument.save("mine", to: url, baseHash: base, inWorkspace: true)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "v2 from elsewhere")
        try FileManager.default.removeItem(at: url)
        #expect(throws: FileSaveFailure.deleted) { try FileDocument.save("mine", to: url, baseHash: base, inWorkspace: true) }
        // A null base hash creates the file only while it is absent.
        #expect(try FileDocument.save("new", to: url, baseHash: nil, inWorkspace: true).written)
        #expect(throws: FileSaveFailure.conflict(hash: FileDocument.hash(Data("new".utf8)), text: "new")) {
            try FileDocument.save("again", to: url, baseHash: nil, inWorkspace: true)
        }
    }

    @Test func nonUTF8BinaryOutsideAndUnwritableFilesOpenReadOnlyAndRefuseSaves() throws {
        let folder = try Self.folder()
        let latin1 = try Self.write([0x63, 0x61, 0x66, 0xE9], "latin1.txt", in: folder)
        #expect(try FileDocument.read(latin1, inWorkspace: true).readOnlyReason == .encoding)
        let binary = try Self.write([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01], "blob.bin", in: folder)
        #expect(try FileDocument.read(binary, inWorkspace: true).readOnlyReason == .binary)
        let text = try Self.write(Array("ok".utf8), "ok.txt", in: folder)
        #expect(try FileDocument.read(text, inWorkspace: false).readOnlyReason == .outside)
        let locked = try Self.write(Array("ok".utf8), "locked.txt", in: folder)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: locked.path)
        #expect(try FileDocument.read(locked, inWorkspace: true).readOnlyReason == .permission)
        for (url, inWorkspace) in [(latin1, true), (binary, true), (text, false), (locked, true)] {
            let base = try FileDocument.read(url, inWorkspace: inWorkspace).hash
            #expect(throws: FileSaveFailure.readOnly) { try FileDocument.save("x", to: url, baseHash: base, inWorkspace: inWorkspace) }
        }
        #expect(try Data(contentsOf: latin1) == Data([0x63, 0x61, 0x66, 0xE9]))
    }

    @Test func missingFoldersAndTooLargeFilesDoNotOpen() throws {
        let folder = try Self.folder()
        #expect(throws: FileOpenFailure.notFound) { try FileDocument.read(folder.appending(path: "gone.txt"), inWorkspace: true) }
        #expect(throws: FileOpenFailure.notFile) { try FileDocument.read(folder, inWorkspace: true) }
        let big = try Self.write(Array(repeating: 0x61, count: 64), "big.txt", in: folder)
        #expect(throws: FileOpenFailure.tooLarge) { try FileDocument.read(big, inWorkspace: true, maximumBytes: 63) }
        #expect(FileDocument.maximumBytes == 200 * 1024 * 1024)
    }

    /// A temporary file and a rename: readers never see half a file, and the file keeps its
    /// permissions and extended attributes. A symbolic link stays a link to the saved file.
    @Test func aSaveRenamesATemporaryFileKeepingModeAndExtendedAttributes() throws {
        let folder = try Self.folder()
        let url = try Self.write(Array("v1".utf8), "script.sh", in: folder)
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: url.path)
        let tag = Data("cmux-test".utf8)
        let set = tag.withUnsafeBytes { setxattr(url.path, "com.cmux.test", $0.baseAddress, tag.count, 0, 0) }
        #expect(set == 0)
        let before = Self.inode(url)
        let base = try FileDocument.read(url, inWorkspace: true).hash
        _ = try FileDocument.save("v2", to: url, baseHash: base, inWorkspace: true)
        #expect(Self.inode(url) != before, "written through a rename")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o750)
        var buffer = [UInt8](repeating: 0, count: 64)
        let length = getxattr(url.path, "com.cmux.test", &buffer, buffer.count, 0, 0)
        #expect(length == tag.count && Data(buffer.prefix(max(length, 0))) == tag)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains("cmux-save") }
        #expect(leftovers.isEmpty)

        let link = folder.appending(path: "link.sh")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        let linked = try FileDocument.read(link, inWorkspace: true)
        _ = try FileDocument.save("v3", to: link, baseHash: linked.hash, inWorkspace: true)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "v3")
    }

    /// Roots are exactly the folders given (the user's choices): no repository top level is
    /// inferred, and home and `/` are never roots.
    @Test func rootsAreTheChosenFoldersAndNeverHome() throws {
        let home = try Self.folder()
        let repo = home.appending(path: "repo", directoryHint: .isDirectory)
        try FileDocumentTests.makeDirectory(repo.appending(path: ".git"))
        try FileDocumentTests.makeDirectory(repo.appending(path: "src/deep"))
        let loose = home.appending(path: "notes", directoryHint: .isDirectory)
        try FileDocumentTests.makeDirectory(loose)
        let deep = repo.appending(path: "src/deep").path
        let roots = FileWorkspaceRoots(folders: [deep, loose.path, home.path, "/", deep], home: home.path)
        #expect(roots.paths == [deep, loose.path])
        #expect(roots.contains(repo.appending(path: "src/deep/a.ts").path))
        #expect(!roots.contains(repo.appending(path: "src/a.ts").path), "the repository is not inferred")
        #expect(roots.contains(loose.appending(path: "todo.md").path))
        #expect(!roots.contains(home.appending(path: "other/a.ts").path))
        #expect(!roots.contains(loose.path + "-sibling/a.ts"))
    }
}

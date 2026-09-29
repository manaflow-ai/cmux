import Darwin
import Foundation
import Testing
@testable import CmuxFoundation

@Suite struct OwnedFileAppendOpenerTests {
    @Test func createsAPrivateFileAndAppends() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let path = directory.path("debug.log")

        try append("one\n", to: path)
        try append("two\n", to: path)

        #expect(try String(contentsOfFile: path, encoding: .utf8) == "one\ntwo\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func narrowsAnExistingOwnedFileToTheCreationMode() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let path = directory.path("debug.log")
        try Data("old\n".utf8).write(to: URL(fileURLWithPath: path))
        try #require(chmod(path, 0o644) == 0)

        try append("new\n", to: path)

        #expect(try String(contentsOfFile: path, encoding: .utf8) == "old\nnew\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func refusesASymbolicLink() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let target = directory.path("target")
        try Data("keep\n".utf8).write(to: URL(fileURLWithPath: target))
        let link = directory.path("debug.log")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        #expect(OwnedFileAppendOpener().openDescriptor(atPath: link) == nil)
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "keep\n")
    }

    @Test func refusesAHardLinkedFile() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let target = directory.path("target")
        try Data("keep\n".utf8).write(to: URL(fileURLWithPath: target))
        let link = directory.path("debug.log")
        try #require(Darwin.link(target, link) == 0)

        #expect(OwnedFileAppendOpener().openDescriptor(atPath: link) == nil)
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "keep\n")
    }

    @Test func refusesAFIFOWithoutBlocking() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let path = directory.path("debug.log")
        try #require(mkfifo(path, 0o600) == 0)

        #expect(OwnedFileAppendOpener().openDescriptor(atPath: path) == nil)
    }

    @Test func refusesAFileOwnedByAnotherUser() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let path = directory.path("debug.log")
        try Data().write(to: URL(fileURLWithPath: path))

        #expect(OwnedFileAppendOpener(expectedOwnerID: geteuid() &+ 1).openDescriptor(atPath: path) == nil)
    }

    private func append(_ text: String, to path: String) throws {
        let handle = try #require(OwnedFileAppendOpener().fileHandle(atPath: path))
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(text.utf8))
    }
}

@Suite struct OwnedFileReplacerTests {
    @Test func stagesAPrivateSiblingBeforeTheTargetChanges() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let path = directory.path("debug.log")
        try Data("old\n".utf8).write(to: URL(fileURLWithPath: path))

        let sibling = try #require(OwnedFileReplacer().stage(Data("new\n".utf8), forPath: path))
        defer { unlink(sibling) }

        var status = stat()
        try #require(lstat(sibling, &status) == 0)
        #expect(status.st_mode & S_IFMT == S_IFREG)
        #expect(status.st_mode & 0o7777 == 0o600)
        #expect(status.st_uid == geteuid())
        #expect(try String(contentsOfFile: sibling, encoding: .utf8) == "new\n")
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "old\n")
    }

    @Test func replacesAWiderFileWithAPrivateOneAndLeavesNoSibling() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let path = directory.path("debug.log")
        try Data("old\n".utf8).write(to: URL(fileURLWithPath: path))
        try #require(chmod(path, 0o644) == 0)

        #expect(OwnedFileReplacer().replaceContents(ofPath: path, with: Data("new\n".utf8)))

        #expect(try String(contentsOfFile: path, encoding: .utf8) == "new\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path) == ["debug.log"])
    }

    @Test func replacesASymbolicLinkWithoutWritingThroughIt() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let target = directory.path("target")
        try Data("keep\n".utf8).write(to: URL(fileURLWithPath: target))
        let link = directory.path("debug.log")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        #expect(OwnedFileReplacer().replaceContents(ofPath: link, with: Data("new\n".utf8)))

        #expect(try String(contentsOfFile: target, encoding: .utf8) == "keep\n")
        #expect(try FileManager.default.attributesOfItem(atPath: link)[.type] as? FileAttributeType == .typeRegular)
    }

    @Test func failsWithoutLeavingASiblingWhenTheDirectoryIsMissing() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }

        #expect(!OwnedFileReplacer().replaceContents(ofPath: directory.path("missing/debug.log"), with: Data()))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
    }
}

@Suite struct OwnedMarkerFileReaderTests {
    @Test func readsAnOwnedMarker() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let path = directory.path("marker")
        try Data("  /tmp/cmux-debug-tag.log\n".utf8).write(to: URL(fileURLWithPath: path))

        #expect(OwnedMarkerFileReader().trimmedContents(atPath: path) == "/tmp/cmux-debug-tag.log")
    }

    @Test func refusesASymbolicLinkMarker() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let target = directory.path("target")
        try Data("/Users/someone/.zshrc\n".utf8).write(to: URL(fileURLWithPath: target))
        let link = directory.path("marker")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        #expect(OwnedMarkerFileReader().trimmedContents(atPath: link) == nil)
    }

    @Test func refusesAMarkerOwnedByAnotherUser() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let path = directory.path("marker")
        try Data("/tmp/cmux-debug.log\n".utf8).write(to: URL(fileURLWithPath: path))

        #expect(OwnedMarkerFileReader(expectedOwnerID: geteuid() &+ 1).trimmedContents(atPath: path) == nil)
    }

    @Test func refusesAHardLinkedMarker() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let target = directory.path("target")
        try Data("/Users/other/.zshrc\n".utf8).write(to: URL(fileURLWithPath: target))
        let marker = directory.path("marker")
        try #require(Darwin.link(target, marker) == 0)

        #expect(OwnedMarkerFileReader().trimmedContents(atPath: marker) == nil)
    }

    @Test func refusesAnOversizedOrEmptyMarker() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let large = directory.path("large")
        try Data(repeating: UInt8(ascii: "a"), count: 64).write(to: URL(fileURLWithPath: large))
        let empty = directory.path("empty")
        try Data(" \n".utf8).write(to: URL(fileURLWithPath: empty))

        #expect(OwnedMarkerFileReader(maximumBytes: 16).trimmedContents(atPath: large) == nil)
        #expect(OwnedMarkerFileReader().trimmedContents(atPath: empty) == nil)
    }
}

private struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-owned-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func path(_ name: String) -> String {
        url.appendingPathComponent(name, isDirectory: false).path
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

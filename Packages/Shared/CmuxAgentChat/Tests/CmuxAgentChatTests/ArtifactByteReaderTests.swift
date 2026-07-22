import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("ArtifactByteReader")
struct ArtifactByteReaderTests {
    @Test("directory listings cap at 500 and report truncation")
    func listCap() throws {
        try withTemporaryDirectory { directory in
            for index in 0...ArtifactByteReader.maximumDirectoryEntryCount {
                let path = directory.appendingPathComponent(String(format: "item-%03d.txt", index))
                #expect(FileManager.default.createFile(atPath: path.path, contents: Data()))
            }

            let listing = try ArtifactByteReader().list(path: directory.path)

            #expect(listing.entries.count == ArtifactByteReader.maximumDirectoryEntryCount)
            #expect(listing.isTruncated)
            #expect(listing.entries.first?.name == "item-000.txt")
            #expect(listing.entries.last?.name == "item-499.txt")
        }
    }

    @Test("listing a file keeps the existing file-not-found semantic")
    func listingFile() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("artifact.txt")
            #expect(FileManager.default.createFile(atPath: file.path, contents: Data("hello".utf8)))

            do {
                _ = try ArtifactByteReader().list(path: file.path)
                Issue.record("listing a file should fail")
            } catch ArtifactByteReader.Error.fileNotFound {
                // Expected wire semantic.
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    @Test("extensionless UTF-8 text is classified as text")
    func extensionlessUTF8Text() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("output")
            try Data("hello, 漢字 and 🙂".utf8).write(to: file)

            #expect(ArtifactByteReader().kind(path: file.path, isDirectory: false) == .text)
        }
    }

    @Test("unknown-extension UTF-8 text is classified as text")
    func unknownExtensionUTF8Text() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("output.cmux-unknown-text-kind")
            try Data("plain text".utf8).write(to: file)

            #expect(ArtifactByteReader().kind(path: file.path, isDirectory: false) == .text)
        }
    }

    @Test("binary junk remains binary")
    func binaryJunk() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("output")
            try Data([0x00, 0xFF, 0xFE, 0x80]).write(to: file)

            #expect(ArtifactByteReader().kind(path: file.path, isDirectory: false) == .binary)
        }
    }

    @Test("empty extensionless files are valid UTF-8 text")
    func emptyFile() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("output")
            try Data().write(to: file)

            #expect(ArtifactByteReader().kind(path: file.path, isDirectory: false) == .text)
        }
    }

    @Test("files smaller than the sniff budget are classified from all bytes")
    func smallerThanSniffBudget() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("output")
            try Data(repeating: 0x61, count: 8 * 1024 - 1).write(to: file)

            #expect(ArtifactByteReader().kind(path: file.path, isDirectory: false) == .text)
        }
    }

    @Test("a multibyte scalar split at the 8 KiB edge is accepted")
    func multibyteScalarSplitAtSniffEdge() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("output")
            var bytes = Data(repeating: 0x61, count: 8 * 1024 - 1)
            bytes.append(contentsOf: "🙂".utf8)
            try bytes.write(to: file)

            #expect(ArtifactByteReader().kind(path: file.path, isDirectory: false) == .text)
        }
    }

    private func withTemporaryDirectory(
        _ operation: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-artifact-list-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try operation(directory)
    }
}

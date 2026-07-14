import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("ArtifactByteReader directory listing")
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

import Darwin
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

    @Test("listing a file is not reported as a missing file")
    func listingFile() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("artifact.txt")
            #expect(FileManager.default.createFile(atPath: file.path, contents: Data("hello".utf8)))

            #expect(throws: ArtifactByteReader.Error.notDirectory) {
                try ArtifactByteReader().list(path: file.path)
            }
        }
    }

    @Test("directory listings do not follow child symlinks")
    func listingSkipsSymlinkChild() throws {
        try withTemporaryDirectory { directory in
            let outside = directory.deletingLastPathComponent()
                .appendingPathComponent("cmux-artifact-list-outside-\(UUID().uuidString)")
            try "private".write(to: outside, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: outside) }
            let link = directory.appendingPathComponent("linked.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

            let listing = try ArtifactByteReader().list(path: directory.path)

            #expect(!listing.entries.contains { $0.name == link.lastPathComponent })
        }
    }

    @Test("directory listings retain readable siblings beside special children")
    func listingRetainsSiblingBesideFIFO() throws {
        try withTemporaryDirectory { directory in
            let fifo = directory.appendingPathComponent("pipe")
            try #require(Darwin.mkfifo(fifo.path, 0o600) == 0)
            let readable = directory.appendingPathComponent("readable.txt")
            try Data("visible".utf8).write(to: readable)

            let listing = try ArtifactByteReader().list(path: directory.path)

            #expect(listing.entries.contains { $0.name == readable.lastPathComponent })
            #expect(listing.entries.first { $0.name == fifo.lastPathComponent }?.kind == .binary)
        }
    }

    @Test("symlink children do not consume the returnable-entry cap")
    func symlinkChildrenDoNotConsumeEntryCap() throws {
        try withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("target.txt")
            try Data("target".utf8).write(to: target)
            for index in 0..<ArtifactByteReader.maximumDirectoryEntryCount {
                let link = directory.appendingPathComponent(String(format: "link-%03d.txt", index))
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            }
            let readable = directory.appendingPathComponent("z-readable.txt")
            try Data("visible".utf8).write(to: readable)

            let listing = try ArtifactByteReader().list(path: directory.path)

            #expect(listing.entries.count == 2)
            #expect(listing.entries.contains { $0.name == readable.lastPathComponent })
            #expect(!listing.isTruncated)
        }
    }

    @Test("descriptor reads reject an ancestor swap after authorization")
    func ancestorSwapAfterAuthorizationIsRejected() throws {
        try withTemporaryDirectory { directory in
            let inside = directory.appendingPathComponent("inside", isDirectory: true)
            let outside = directory.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let insideFile = inside.appendingPathComponent("artifact.txt")
            let outsideFile = outside.appendingPathComponent("artifact.txt")
            try Data("authorized".utf8).write(to: insideFile)
            try Data("outside".utf8).write(to: outsideFile)
            let authorizedPath = insideFile.path
            let authorizedCanonicalPath = insideFile
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path

            try FileManager.default.removeItem(at: inside)
            try FileManager.default.createSymbolicLink(at: inside, withDestinationURL: outside)

            #expect(throws: ArtifactByteReader.Error.fileNotFound) {
                _ = try ArtifactByteReader().fetch(
                    path: authorizedPath,
                    offset: 0,
                    length: 64,
                    authorizedCanonicalPath: authorizedCanonicalPath
                )
            }
            #expect(throws: ArtifactByteReader.Error.fileNotFound) {
                _ = try ArtifactByteReader().stat(
                    path: authorizedPath,
                    authorizedCanonicalPath: authorizedCanonicalPath
                )
            }
        }
    }

    @Test("descriptor reads reject an inode replacement at the authorized path")
    func inodeReplacementAfterAuthorizationIsRejected() throws {
        try withTemporaryDirectory { directory in
            let authorized = directory.appendingPathComponent("authorized.txt")
            let replacement = directory.appendingPathComponent("replacement.txt")
            try Data("authorized".utf8).write(to: authorized)
            try Data("replacement".utf8).write(to: replacement)
            let authorizedCanonicalPath = authorized
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
            let authorizedIdentity = try ArtifactByteReader().identity(
                path: authorized.path,
                authorizedCanonicalPath: authorizedCanonicalPath
            )

            try FileManager.default.removeItem(at: authorized)
            try FileManager.default.linkItem(at: replacement, to: authorized)

            #expect(throws: ArtifactByteReader.Error.fileNotFound) {
                _ = try ArtifactByteReader().fetch(
                    path: authorized.path,
                    offset: 0,
                    length: 64,
                    authorizedCanonicalPath: authorizedCanonicalPath,
                    authorizedIdentity: authorizedIdentity
                )
            }
        }
    }

    @Test("a path removed from the Mac is reported as missing")
    func missingPath() throws {
        try withTemporaryDirectory { directory in
            let missing = directory.appendingPathComponent("removed.txt")
            let reader = ArtifactByteReader()

            #expect(throws: ArtifactByteReader.Error.fileNotFound) {
                try reader.stat(path: missing.path)
            }
            #expect(throws: ArtifactByteReader.Error.fileNotFound) {
                try reader.fetch(path: missing.path, offset: 0, length: 16)
            }
        }
    }

    @Test("permission denial is not reported as a missing file")
    func permissionDenied() throws {
        try withTemporaryDirectory { directory in
            guard Darwin.geteuid() != 0 else { return }
            let file = directory.appendingPathComponent("private.txt")
            try Data("secret".utf8).write(to: file)
            try #require(Darwin.chmod(file.path, 0o000) == 0)
            defer { _ = Darwin.chmod(file.path, 0o600) }

            #expect(throws: ArtifactByteReader.Error.permissionDenied) {
                try ArtifactByteReader().fetch(path: file.path, offset: 0, length: 16)
            }
        }
    }

    @Test("damaged image data is not reported as an unsupported file type")
    func damagedImage() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("damaged.png")
            try Data("not a png".utf8).write(to: file)

            #expect(throws: ArtifactByteReader.Error.corruptMedia) {
                try ArtifactByteReader().thumbnail(path: file.path, maxDimension: 128)
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

    @Test("FIFO metadata is classified without opening the pipe")
    func fifoStat() throws {
        try withTemporaryDirectory { directory in
            let fifo = directory.appendingPathComponent("pipe")
            try #require(Darwin.mkfifo(fifo.path, 0o600) == 0)
            let clock = ContinuousClock()
            let start = clock.now

            let stat = try ArtifactByteReader().stat(path: fifo.path)

            #expect(!stat.isDirectory)
            #expect(stat.kind == .binary)
            #expect(clock.now - start < .seconds(1))
        }
    }

    @Test("FIFO metadata ignores an image extension without opening the pipe")
    func imageExtensionFifoStat() throws {
        try withTemporaryDirectory { directory in
            let fifo = directory.appendingPathComponent("preview.png")
            try #require(Darwin.mkfifo(fifo.path, 0o600) == 0)
            let clock = ContinuousClock()
            let start = clock.now

            let stat = try ArtifactByteReader().stat(path: fifo.path)

            #expect(!stat.isDirectory)
            #expect(stat.kind == .binary)
            #expect(clock.now - start < .seconds(1))
        }
    }

    @Test("FIFO bytes are rejected without opening the pipe")
    func fifoFetch() throws {
        try withTemporaryDirectory { directory in
            let fifo = directory.appendingPathComponent("pipe")
            try #require(Darwin.mkfifo(fifo.path, 0o600) == 0)
            let clock = ContinuousClock()
            let start = clock.now

            do {
                _ = try ArtifactByteReader().fetch(path: fifo.path, offset: 0, length: 1)
                Issue.record("fetching a FIFO should fail")
            } catch ArtifactByteReader.Error.notRegularFile {
                // Expected: opening a FIFO for reading could block indefinitely.
            } catch {
                Issue.record("unexpected error: \(error)")
            }

            #expect(clock.now - start < .seconds(1))
        }
    }

    @Test("FIFO thumbnails ignore an image extension without opening the pipe")
    func imageExtensionFifoThumbnail() throws {
        try withTemporaryDirectory { directory in
            let fifo = directory.appendingPathComponent("preview.png")
            try #require(Darwin.mkfifo(fifo.path, 0o600) == 0)
            let clock = ContinuousClock()
            let start = clock.now

            do {
                _ = try ArtifactByteReader().thumbnail(path: fifo.path, maxDimension: 128)
                Issue.record("thumbnailing a FIFO should fail")
            } catch ArtifactByteReader.Error.notRegularFile {
                // Expected: ImageIO must never open an unverified FIFO path.
            } catch {
                Issue.record("unexpected error: \(error)")
            }

            #expect(clock.now - start < .seconds(1))
        }
    }

    @Test("descriptor validation rejects a FIFO without blocking")
    func fifoDescriptorValidation() throws {
        try withTemporaryDirectory { directory in
            let fifo = directory.appendingPathComponent("pipe")
            try #require(Darwin.mkfifo(fifo.path, 0o600) == 0)
            let clock = ContinuousClock()
            let start = clock.now

            do {
                let opened = try ArtifactByteReader().openVerifiedRegularFile(path: fifo.path)
                try? opened.handle.close()
                Issue.record("descriptor validation should reject a FIFO")
            } catch ArtifactByteReader.Error.notRegularFile {
                // Expected: the nonblocking descriptor is identified as a FIFO.
            } catch {
                Issue.record("unexpected error: \(error)")
            }

            #expect(clock.now - start < .seconds(1))
        }
    }

    @Test("missing files retain extension-derived kinds")
    func missingFileExtensionKinds() throws {
        try withTemporaryDirectory { directory in
            let missingImage = directory.appendingPathComponent("missing.png")
            let missingExtensionless = directory.appendingPathComponent("missing-extensionless")
            let reader = ArtifactByteReader()

            #expect(reader.kind(path: missingImage.path, isDirectory: false) == .image)
            #expect(reader.kind(path: missingExtensionless.path, isDirectory: false) == .binary)
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

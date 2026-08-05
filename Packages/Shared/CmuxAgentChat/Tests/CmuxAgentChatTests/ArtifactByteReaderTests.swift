import Darwin
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

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
            } catch ArtifactByteReader.Error.unsupportedMedia {
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
            } catch ArtifactByteReader.Error.unsupportedMedia {
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
            } catch ArtifactByteReader.Error.unsupportedMedia {
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

    @Test("image stat includes intrinsic pixel dimensions")
    func imageStatIncludesPixelDimensions() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("preview.png")
            try Self.writePNG(width: 16, height: 9, to: file)

            let stat = try ArtifactByteReader().stat(path: file.path)

            #expect(stat.kind == .image)
            #expect(stat.mimeType == "image/png")
            #expect(stat.pixelWidth == 16)
            #expect(stat.pixelHeight == 9)
        }
    }

    @Test("SVG stat includes declared pixel dimensions")
    func svgStatIncludesDeclaredPixelDimensions() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("preview.svg")
            try Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="480" height="270" viewBox="0 0 480 270"></svg>"#.utf8).write(to: file)

            let stat = try ArtifactByteReader().stat(path: file.path)

            #expect(stat.kind == .image)
            #expect(stat.mimeType == "image/svg+xml")
            #expect(stat.pixelWidth == 480)
            #expect(stat.pixelHeight == 270)
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

    private static func writePNG(width: Int, height: Int, to url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            Issue.record("Failed to create test image context")
            return
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
              ) else {
            Issue.record("Failed to create test image destination")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            Issue.record("Failed to finalize test PNG")
            return
        }
    }
}

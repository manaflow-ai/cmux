import Foundation
import Testing
@testable import CmuxMobileSupport

@Suite("Mobile attachment staging")
struct MobileAttachmentStagerTests {
    @Test func preservesOriginalNameAndExactBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bytes = Data((0..<(8 * 1024 * 1024 + 17)).map { UInt8($0 % 251) })
        let originalName = "- draft 'quote' 資料 📎.png"
        let source = fixture.source.appendingPathComponent(originalName)
        try bytes.write(to: source)

        let attachment = try await fixture.stager.stage(
            sourceURL: source,
            kind: .image,
            originalFileName: originalName
        )

        #expect(attachment.fileName == originalName)
        #expect(attachment.kind == .image)
        #expect(attachment.byteCount == bytes.count)
        #expect(try Data(contentsOf: attachment.localFileURL) == bytes)
        #expect(attachment.localFileURL.deletingLastPathComponent() == fixture.staged)
    }

    @Test func traversalComponentsCannotEscapeStagingRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.source.appendingPathComponent("safe.txt")
        try Data("payload".utf8).write(to: source)

        let attachment = try await fixture.stager.stage(
            sourceURL: source,
            kind: .file,
            originalFileName: "../../outside.txt"
        )

        #expect(attachment.fileName == "outside.txt")
        #expect(attachment.localFileURL.deletingLastPathComponent() == fixture.staged)
        #expect(try Data(contentsOf: attachment.localFileURL) == Data("payload".utf8))
    }

    @Test func duplicateDisplayNamesKeepStableIndependentBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let firstURL = fixture.source.appendingPathComponent("first")
        let secondURL = fixture.source.appendingPathComponent("second")
        try Data("one".utf8).write(to: firstURL)
        try Data("two".utf8).write(to: secondURL)

        let first = try await fixture.stager.stage(
            sourceURL: firstURL,
            kind: .file,
            originalFileName: "report.txt"
        )
        let second = try await fixture.stager.stage(
            sourceURL: secondURL,
            kind: .file,
            originalFileName: "report.txt"
        )

        #expect(first.fileName == "report.txt")
        #expect(second.fileName == "report.txt")
        #expect(first.localFileURL != second.localFileURL)
        #expect(try Data(contentsOf: first.localFileURL) == Data("one".utf8))
        #expect(try Data(contentsOf: second.localFileURL) == Data("two".utf8))
    }

    @Test func rejectsHundredMegabyteFileBeforeCreatingAStagedCopy() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.source.appendingPathComponent("hundred-megabytes.bin")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 100 * 1024 * 1024)
        try handle.close()

        await #expect(throws: MobileAttachmentStager.StagingError.fileTooLarge) {
            try await fixture.stager.stage(
                sourceURL: source,
                kind: .file,
                originalFileName: source.lastPathComponent
            )
        }
        #expect(
            try FileManager.default.contentsOfDirectory(
                at: fixture.staged,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    @Test func cancellationBeforeStagingLeavesNoAppOwnedFile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.source.appendingPathComponent("cancelled.txt")
        try Data("never copied".utf8).write(to: source)

        let staging = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.stager.stage(
                sourceURL: source,
                kind: .file,
                originalFileName: source.lastPathComponent
            )
        }
        await #expect(throws: CancellationError.self) {
            try await staging.value
        }
        #expect(
            try FileManager.default.contentsOfDirectory(
                at: fixture.staged,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    private struct Fixture {
        let root: URL
        let source: URL
        let staged: URL
        let stager: MobileAttachmentStager

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-mobile-attachment-tests-\(UUID())", isDirectory: true)
            source = root.appendingPathComponent("source", isDirectory: true)
            staged = root.appendingPathComponent("staged", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            stager = MobileAttachmentStager(
                rootURL: staged,
                fileManager: FileManager()
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

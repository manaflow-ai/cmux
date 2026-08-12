import Foundation
import Testing
@testable import CmuxControlSocket

@Suite("Mobile task attachment store")
struct MobileTaskAttachmentStoreTests {
    @Test func chunkedUploadFinalizesAndRetryReturnsSamePath() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let operationID = UUID()
        let uploadID = UUID()

        let first = try fixture.store.upload(.init(
            operationID: operationID,
            uploadID: uploadID,
            fileName: "../.notes.txt",
            totalBytes: 5,
            offset: 0,
            dataBase64: Data("he".utf8).base64EncodedString(),
            isLast: false
        ))
        #expect(first.receivedBytes == 2)
        #expect(first.path == nil)

        let final = try fixture.store.upload(.init(
            operationID: operationID,
            uploadID: uploadID,
            fileName: "../.notes.txt",
            totalBytes: 5,
            offset: 2,
            dataBase64: Data("llo".utf8).base64EncodedString(),
            isLast: true
        ))
        let path = try #require(final.path)
        #expect(URL(fileURLWithPath: path).lastPathComponent == "_.notes.txt")
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("hello".utf8))

        let retry = try fixture.store.upload(.init(
            operationID: operationID,
            uploadID: uploadID,
            fileName: "different.txt",
            totalBytes: 99,
            offset: 99,
            dataBase64: "",
            isLast: true
        ))
        #expect(retry.path == path)
        #expect(retry.receivedBytes == 5)
    }

    @Test func retryFromZeroRestartsAnIncompleteUpload() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let operationID = UUID()
        let uploadID = UUID()

        _ = try fixture.store.upload(.init(
            operationID: operationID,
            uploadID: uploadID,
            fileName: "notes.txt",
            totalBytes: 5,
            offset: 0,
            dataBase64: Data("old".utf8).base64EncodedString(),
            isLast: false
        ))
        let restarted = try fixture.store.upload(.init(
            operationID: operationID,
            uploadID: uploadID,
            fileName: "notes.txt",
            totalBytes: 5,
            offset: 0,
            dataBase64: Data("ne".utf8).base64EncodedString(),
            isLast: false
        ))
        #expect(restarted.receivedBytes == 2)

        let completed = try fixture.store.upload(.init(
            operationID: operationID,
            uploadID: uploadID,
            fileName: "notes.txt",
            totalBytes: 5,
            offset: 2,
            dataBase64: Data("wer".utf8).base64EncodedString(),
            isLast: true
        ))
        let path = try #require(completed.path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("newer".utf8))
    }

    @Test func retryFromZeroStillRejectsChangedMetadata() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let operationID = UUID()
        let uploadID = UUID()

        _ = try fixture.store.upload(.init(
            operationID: operationID,
            uploadID: uploadID,
            fileName: "notes.txt",
            totalBytes: 5,
            offset: 0,
            dataBase64: Data("he".utf8).base64EncodedString(),
            isLast: false
        ))
        #expect(throws: MobileTaskAttachmentStoreError.self) {
            try fixture.store.upload(.init(
                operationID: operationID,
                uploadID: uploadID,
                fileName: "changed.txt",
                totalBytes: 5,
                offset: 0,
                dataBase64: Data("ne".utf8).base64EncodedString(),
                isLast: false
            ))
        }

        let completed = try fixture.store.upload(.init(
            operationID: operationID,
            uploadID: uploadID,
            fileName: "notes.txt",
            totalBytes: 5,
            offset: 2,
            dataBase64: Data("llo".utf8).base64EncodedString(),
            isLast: true
        ))
        let path = try #require(completed.path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("hello".utf8))
    }

    @Test func duplicateNamesReceiveNumericSuffixes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let operationID = UUID()

        let first = try fixture.complete(
            operationID: operationID,
            uploadID: UUID(),
            fileName: "report.txt",
            contents: "one"
        )
        let second = try fixture.complete(
            operationID: operationID,
            uploadID: UUID(),
            fileName: "report.txt",
            contents: "two"
        )

        #expect(URL(fileURLWithPath: try #require(first.path)).lastPathComponent == "report.txt")
        #expect(URL(fileURLWithPath: try #require(second.path)).lastPathComponent == "report-2.txt")
    }

    @Test func emptyFinalChunkProducesACompletedRegularFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let result = try fixture.store.upload(.init(
            operationID: UUID(),
            uploadID: UUID(),
            fileName: "empty.txt",
            totalBytes: 0,
            offset: 0,
            dataBase64: "",
            isLast: true
        ))

        let path = try #require(result.path)
        #expect(result.receivedBytes == 0)
        #expect(try URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)).isEmpty)
    }

    @Test func completedAttachmentLookupReturnsOnlyValidatedUploadBytes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let operationID = UUID()
        let uploadID = UUID()
        let completed = try fixture.complete(
            operationID: operationID,
            uploadID: uploadID,
            fileName: "- prompt 'quoted' 資料 📎.txt",
            contents: "exact staged bytes"
        )

        let resolved = try fixture.store.completedAttachmentURL(
            operationID: operationID,
            uploadID: uploadID
        )

        #expect(resolved.path == completed.path)
        #expect(resolved.lastPathComponent == "- prompt 'quoted' 資料 📎.txt")
        #expect(try Data(contentsOf: resolved) == Data("exact staged bytes".utf8))
        #expect(throws: MobileTaskAttachmentStoreError.self) {
            try fixture.store.completedAttachmentURL(
                operationID: operationID,
                uploadID: UUID()
            )
        }
    }

    @Test func completedAttachmentLookupRejectsSymlinksEscapingTheOperationDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let operationID = UUID()
        let uploadID = UUID()
        let completed = try fixture.complete(
            operationID: operationID,
            uploadID: uploadID,
            fileName: "inside.txt",
            contents: "inside"
        )
        let completedURL = URL(fileURLWithPath: try #require(completed.path))
        let outsideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-attachment-outside-\(UUID()).txt")
        try Data("outside".utf8).write(to: outsideURL)
        defer { try? FileManager.default.removeItem(at: outsideURL) }
        try FileManager.default.removeItem(at: completedURL)
        try FileManager.default.createSymbolicLink(at: completedURL, withDestinationURL: outsideURL)

        #expect(throws: MobileTaskAttachmentStoreError.self) {
            try fixture.store.completedAttachmentURL(
                operationID: operationID,
                uploadID: uploadID
            )
        }
    }

    @Test func completedAttachmentLookupReturnsResolvedInRootRegularFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let operationID = UUID()
        let uploadID = UUID()
        let completed = try fixture.complete(
            operationID: operationID,
            uploadID: uploadID,
            fileName: "linked.txt",
            contents: "linked"
        )
        let completedURL = URL(fileURLWithPath: try #require(completed.path))
        let targetURL = completedURL.deletingLastPathComponent()
            .appendingPathComponent("resolved.txt")
        try FileManager.default.moveItem(at: completedURL, to: targetURL)
        try FileManager.default.createSymbolicLink(at: completedURL, withDestinationURL: targetURL)

        let resolved = try fixture.store.completedAttachmentURL(
            operationID: operationID,
            uploadID: uploadID
        )

        #expect(resolved == targetURL.resolvingSymlinksInPath().standardizedFileURL)
        #expect(try Data(contentsOf: resolved) == Data("linked".utf8))
    }

    @Test func completedAttachmentLookupRejectsOperationDirectorySymlinkEscape() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let operationID = UUID()
        let uploadID = UUID()
        let completed = try fixture.complete(
            operationID: operationID,
            uploadID: uploadID,
            fileName: "escaped.txt",
            contents: "escaped"
        )
        let completedURL = URL(fileURLWithPath: try #require(completed.path))
        let operationURL = completedURL.deletingLastPathComponent()
        let outsideOperationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-operation-outside-\(UUID())")
        defer { try? FileManager.default.removeItem(at: outsideOperationURL) }
        try FileManager.default.moveItem(at: operationURL, to: outsideOperationURL)
        try FileManager.default.createSymbolicLink(
            at: operationURL,
            withDestinationURL: outsideOperationURL
        )

        #expect(throws: MobileTaskAttachmentStoreError.self) {
            try fixture.store.completedAttachmentURL(
                operationID: operationID,
                uploadID: uploadID
            )
        }
    }

    @Test func batchLookupFailsBeforeReturningAnyPathWhenLaterReferenceIsInvalid() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let operationID = UUID()
        let firstID = UUID()
        _ = try fixture.complete(
            operationID: operationID,
            uploadID: firstID,
            fileName: "first.txt",
            contents: "first"
        )

        #expect(throws: MobileTaskAttachmentStoreError.self) {
            try fixture.store.completedAttachmentURLs(references: [
                .init(operationID: operationID, uploadID: firstID),
                .init(operationID: operationID, uploadID: UUID()),
            ])
        }
    }

    @Test func rejectsOutOfOrderAndOversizedRequests() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(throws: MobileTaskAttachmentStoreError.self) {
            try fixture.store.upload(.init(
                operationID: UUID(),
                uploadID: UUID(),
                fileName: "bad.txt",
                totalBytes: 2,
                offset: 1,
                dataBase64: Data("x".utf8).base64EncodedString(),
                isLast: false
            ))
        }
        #expect(throws: MobileTaskAttachmentStoreError.self) {
            try fixture.store.upload(.init(
                operationID: UUID(),
                uploadID: UUID(),
                fileName: "huge.bin",
                totalBytes: MobileTaskAttachmentStore.maximumFileBytes + 1,
                offset: 0,
                dataBase64: "",
                isLast: true
            ))
        }
    }

    @Test func enforcesAttachmentCountAndPrunesExpiredOperations() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let fixture = try Fixture(now: now)
        defer { fixture.remove() }
        let operationID = UUID()
        for index in 0..<MobileTaskAttachmentStore.maximumAttachmentsPerOperation {
            _ = try fixture.complete(
                operationID: operationID,
                uploadID: UUID(),
                fileName: "\(index).txt",
                contents: ""
            )
        }
        #expect(throws: MobileTaskAttachmentStoreError.self) {
            try fixture.complete(
                operationID: operationID,
                uploadID: UUID(),
                fileName: "overflow.txt",
                contents: ""
            )
        }

        let expired = fixture.root.appendingPathComponent("expired", isDirectory: true)
        try FileManager.default.createDirectory(
            at: expired,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(
                -MobileTaskAttachmentStore.retentionInterval - 1
            )],
            ofItemAtPath: expired.path
        )
        _ = try fixture.complete(
            operationID: UUID(),
            uploadID: UUID(),
            fileName: "fresh.txt",
            contents: ""
        )
        #expect(!FileManager.default.fileExists(atPath: expired.path))
    }

    private struct Fixture {
        let root: URL
        let store: MobileTaskAttachmentStore

        init(now: Date = Date()) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-task-attachment-tests-\(UUID())")
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            store = MobileTaskAttachmentStore(
                rootURL: root,
                now: now,
                fileManager: FileManager()
            )
        }

        func complete(
            operationID: UUID,
            uploadID: UUID,
            fileName: String,
            contents: String
        ) throws -> MobileTaskAttachmentUploadResult {
            let data = Data(contents.utf8)
            return try store.upload(.init(
                operationID: operationID,
                uploadID: uploadID,
                fileName: fileName,
                totalBytes: data.count,
                offset: 0,
                dataBase64: data.base64EncodedString(),
                isLast: true
            ))
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

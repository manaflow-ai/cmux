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

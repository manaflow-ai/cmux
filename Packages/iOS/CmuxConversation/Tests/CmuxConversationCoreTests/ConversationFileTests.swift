import Foundation
import Testing
@testable import CmuxConversationCore

/// Records file uploads made through `ScriptedBackend` (it stays file-capable
/// for every suite; the other suites never upload files).
private let fileUploads = FileUploadLog()

private final class FileUploadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _infos: [ConversationFileInfo] = []
    var infos: [ConversationFileInfo] { lock.withLock { _infos } }
    func append(_ info: ConversationFileInfo) { lock.withLock { _infos.append(info) } }
}

extension ScriptedBackend: ConversationFileBackend {
    func uploadFileAttachment(_ data: Data, info: ConversationFileInfo) async throws -> ConversationAttachment {
        fileUploads.append(info)
        return ConversationAttachment(id: "file-\(info.name)", kind: .file, width: 0, height: 0, url: nil, file: info)
    }
}

@MainActor
@Suite struct ConversationFileTests {
    @Test func infoInfersTheTypeFromTheNameThenTheMIMEType() {
        let pdf = ConversationFileInfo(name: "Quarterly Report.pdf", mimeType: nil, byteCount: 1_234_567)
        #expect(pdf.uti == "com.adobe.pdf")
        #expect(pdf.mimeType == "application/pdf")
        #expect(!pdf.isImage)
        #expect(pdf.formattedSize == ByteCountFormatter.string(fromByteCount: 1_234_567, countStyle: .file))

        let zip = ConversationFileInfo(name: "logs", mimeType: "application/zip", byteCount: 10)
        #expect(zip.uti == "public.zip-archive")

        let unknown = ConversationFileInfo(name: "blob.unknownext", mimeType: "application/x-nothing-known", byteCount: 1)
        #expect(unknown.uti == "public.data")
        #expect(unknown.mimeType == "application/octet-stream")

        let png = ConversationPendingFile(data: Data([1, 2, 3]), name: "Sunset.png")
        #expect(png.info.isImage)
        #expect(png.info.byteCount == 3)
    }

    @Test func wireDecodesFileAttachments() throws {
        let base = URL(string: "http://127.0.0.1:4870")!
        let attachment = try #require(WireDecoding.attachment([
            "id": "file_1",
            "kind": "file",
            "name": "notes.txt",
            "mimeType": "text/plain",
            "size": 2048,
            "url": "/media/file_1.txt",
        ], base: base))
        #expect(attachment.kind == .file)
        #expect(attachment.width == 0)
        #expect(attachment.url?.absoluteString == "http://127.0.0.1:4870/media/file_1.txt")
        let file = try #require(attachment.file)
        #expect(file.name == "notes.txt")
        #expect(file.uti == "public.plain-text")
        #expect(file.byteCount == 2048)

        // An explicit uti wins over the inferred one.
        let explicit = try #require(WireDecoding.attachment(["id": "f", "kind": "file", "name": "a.bin", "uti": "com.example.custom", "size": 1], base: base))
        #expect(explicit.file?.uti == "com.example.custom")
        // Images and audio carry no file details.
        #expect(WireDecoding.attachment(["id": "img", "width": 10, "height": 20], base: base)?.file == nil)
    }

    @Test func sendFileShowsTheDocumentAtOnceThenUploadsAndAcks() async throws {
        let backend = ScriptedBackend(total: 5)
        let store = ConversationStore(backend: backend, pageSize: 30, makeClientMessageID: { "file-send-1" })
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }

        backend.holdSend = true
        let data = Data("hello".utf8)
        let file = ConversationPendingFile(data: data, name: "Plan-\(UUID().uuidString.prefix(6)).pdf")
        let rowID = try #require(store.send(text: "", files: [file]))
        let pending = try #require(store.message(rowID: rowID))
        #expect(pending.delivery == .sending)
        #expect(pending.fileAttachments.count == 1)
        #expect(pending.fileAttachments.first?.localData == data)
        #expect(pending.fileAttachments.first?.file == file.info)
        #expect(pending.attachments.allSatisfy { $0.kind == .file })

        backend.releaseSend()
        try await waitUntil { store.message(rowID: rowID)?.seq != nil }
        #expect(fileUploads.infos.contains(file.info))
        let draft = try #require(backend.sentDrafts.last)
        #expect(draft.attachmentIDs == ["file-\(file.info.name)"])
    }

    @Test func retryResendsFilesAsFilesNotImages() async throws {
        let backend = ScriptedBackend(total: 1)
        let store = ConversationStore(backend: backend, pageSize: 30, makeClientMessageID: { "file-retry-1" })
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }

        backend.failNextSend = true
        let file = ConversationPendingFile(data: Data([0x50, 0x4B]), name: "Logs-\(UUID().uuidString.prefix(6)).zip")
        let rowID = try #require(store.send(text: "logs", files: [file]))
        try await waitUntil { store.message(rowID: rowID)?.delivery?.isFailed == true }
        let uploadsBefore = fileUploads.infos.filter { $0 == file.info }.count

        store.retry(rowID: rowID)
        try await waitUntil { store.message(rowID: rowID)?.seq != nil }
        #expect(fileUploads.infos.filter { $0 == file.info }.count == uploadsBefore + 1)
        #expect(backend.sentDrafts.last?.attachmentIDs == ["file-\(file.info.name)"])
    }

    @Test func accessibilityNamesTheDocument() {
        var message = ConversationMessage(id: "m", seq: 1, clientMessageID: nil, senderID: "lc", sentAt: Date(timeIntervalSince1970: 0), text: "")
        message.attachments = [ConversationAttachment(id: "f", kind: .file, width: 0, height: 0, url: nil, file: ConversationFileInfo(name: "notes.txt", uti: "public.plain-text", byteCount: 2048))]
        let label = ConversationAccessibilityText.messageLabel(message, isOutgoing: false, senderName: "Lawrence", reactorName: { _ in nil }, time: "9:41")
        #expect(label.contains("notes.txt"))
    }
}

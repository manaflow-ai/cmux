import CmuxHomeCore
import Foundation
import Testing
@testable import CmuxNextApp

/// With no connection to the local Chief owner, `DaemonHomeSource` sends
/// nothing and says so (`HomeOwnerOffline`), so a send under an online cloud
/// waits for the owner and never shows "May Not Have Been Delivered".
@Suite(.timeLimit(.minutes(1))) struct DaemonHomeSourceOwnerOfflineTests {
    let source = DaemonHomeSource(
        me: Participant(id: ParticipantID("user_local"), kind: .human, displayName: "Me"),
        attachmentCache: FileManager.default.temporaryDirectory.appendingPathComponent("dhs-offline-\(UUID().uuidString)"))

    @Test func aSubmitWithoutTheOwnerSendsNothing() async {
        let intent = HomeIntent(key: IdempotencyKey("offline-1"),
                                op: .sendMessage(conversation: ConversationID("conv_local"), parts: [.text("hi")]))
        await #expect(throws: HomeOwnerOffline.self) { try await source.submit(intent) }
    }

    @Test func anUploadWithoutTheOwnerSendsNothing() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dhs-offline-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let ref = AttachmentRef(hash: String(repeating: "a", count: 64), name: "x.txt", mimeType: "text/plain", byteCount: 1)
        let upload = AttachmentUpload(conversation: ConversationID("conv_local"), fileURL: file, ref: ref) { _ in }
        await #expect(throws: HomeOwnerOffline.self) { try await source.upload(upload) }
    }
}

@testable import CmuxHomeCore
import Foundation
import Synchronization
import Testing
@testable import CmuxNextApp

/// A local owner that stores attachments: records each upload and fetch.
nonisolated final class AttachmentLocalHomeSource: HomeSource {
    let base = FakeLocalHomeSource()
    private let calls = Mutex<[String]>([])
    var log: [String] { calls.withLock { $0 } }

    func events() async -> AsyncStream<HomeEvent> { await base.events() }
    func inbox() async throws -> InboxSnapshot { try await base.inbox() }
    func snapshot(of conversation: ConversationID, tail: Int) async throws -> ConversationPage {
        try await base.snapshot(of: conversation, tail: tail)
    }
    func history(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) async throws -> [Message] { [] }
    func submit(_ intent: HomeIntent) async throws -> HomeOpResult { try await base.submit(intent) }
    func search(_ query: String, limit: Int) async throws -> [HomeSearchHit] { [] }
    func resolve(_ contact: ContactAddress) async throws -> ContactResolution { .invitable(contact) }
    func upload(_ file: AttachmentUpload) async throws -> AttachmentRef {
        calls.withLock { $0.append("upload \(file.conversation.rawValue) \(file.ref.hash)") }
        return file.ref
    }
    func fetch(_ ref: AttachmentRef, at location: AttachmentLocation, variant: AttachmentVariant) async throws -> URL {
        calls.withLock { $0.append("fetch \(location.conversation.rawValue) \(ref.hash)") }
        return URL(fileURLWithPath: "/dev/null")
    }
}

/// Attachments to the local Chief go through the router to the local owner
/// (live incident 2026-10-09: every photo sent to the Chief showed "Not
/// Delivered" with `invalid: attachments unsupported`, the protocol
/// default, because the router did not forward uploads).
@Suite(.timeLimit(.minutes(1))) nonisolated struct HomeSourceRouterAttachmentTests {
    @Test func uploadsAndFetchesReachTheLocalOwner() async throws {
        let local = AttachmentLocalHomeSource()
        let router = HomeSourceRouter(local: local, cloud: CloudHomeSource(me: local.base.me))
        let conversation = FakeLocalHomeSource.conversation
        let ref = AttachmentRef(hash: "abc", name: "a.png", mimeType: "image/png", byteCount: 3, width: 4, height: 5)
        let stored = try await router.upload(AttachmentUpload(conversation: conversation, fileURL: URL(fileURLWithPath: "/dev/null"), ref: ref))
        #expect(stored.hash == "abc")
        _ = try await router.fetch(ref, at: AttachmentLocation(conversation: conversation), variant: .original)
        #expect(local.log == ["upload \(conversation.rawValue) abc", "fetch \(conversation.rawValue) abc"])
    }
}

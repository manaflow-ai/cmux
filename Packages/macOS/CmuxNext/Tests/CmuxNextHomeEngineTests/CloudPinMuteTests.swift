import CmuxHomeCore
import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// Pin and mute of a Cloud conversation are the person's own inbox state
/// (UserDO `inbox.pin`, `inbox.mute`): the Cloud source sends them to the
/// daemon's `cloud-inbox-op` with the intent's key, instead of refusing them
/// as `unsupported_op`.
struct CloudPinMuteTests {
    static let conversation = ConversationID("conv_pinmute")

    @Test func pinGoesToTheInboxWithTheIntentsKey() async throws {
        let daemon = FakeCloudDaemon()
        let source = CloudSourceHarness.connected(to: daemon)
        let intent = HomeIntent(key: IdempotencyKey("pin-1"), op: .setPinned(conversation: Self.conversation, rank: 3))
        let result = try await source.submit(intent)
        #expect(result.conversation == Self.conversation)
        let ops = await daemon.inboxOps
        #expect(ops == [FakeCloudDaemon.InboxOp(conversation: Self.conversation.rawValue, idempotencyKey: "pin-1",
                                                op: .pin(true, position: 3))])
    }

    @Test func unpinSendsPinnedFalse() async throws {
        let daemon = FakeCloudDaemon()
        let source = CloudSourceHarness.connected(to: daemon)
        _ = try await source.submit(HomeIntent(key: IdempotencyKey("unpin-1"), op: .setPinned(conversation: Self.conversation, rank: nil)))
        #expect(await daemon.inboxOps.map(\.op) == [.pin(false)])
    }

    @Test func muteAndUnmuteGoToTheInbox() async throws {
        let daemon = FakeCloudDaemon()
        let source = CloudSourceHarness.connected(to: daemon)
        _ = try await source.submit(HomeIntent(key: IdempotencyKey("mute-1"), op: .setMuted(conversation: Self.conversation, muted: true)))
        _ = try await source.submit(HomeIntent(key: IdempotencyKey("mute-2"), op: .setMuted(conversation: Self.conversation, muted: false)))
        let ops = await daemon.inboxOps
        #expect(ops.map(\.op) == [.mute(true), .mute(false)])
        #expect(ops.map(\.idempotencyKey) == ["mute-1", "mute-2"])
    }
}

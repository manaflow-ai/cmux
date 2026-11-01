import CmuxHomeCore
import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// The Cloud inbox is every page the owner has (`inbox.list` pages by 200, `next_cursor`), not its
/// newest 200: Home listed only the first page, so a Chief or conversation past it never showed and
/// left the list on each refresh.
struct CloudInboxPagingTests {
    static func entry(_ conversation: String, lastSeq: UInt64 = 1) -> CloudInboxEntry {
        CloudInboxEntry(conversation: conversation, rev: 1, kind: "chief", lastSeq: lastSeq, lastAt: "2026-10-29T00:00:00.000Z")
    }

    static let identity = CloudIdentity(stackUserID: "stack-user-1", displayName: "Me", localID: CloudSourceHarness.me.id)

    @Test func everyPageIsReadOnceWithTheFirstPagesRevision() async throws {
        let daemon = FakeCloudDaemon()
        await daemon.scriptInbox([
            "": CloudInboxList(entries: [Self.entry("conv_a"), Self.entry("conv_b")], revision: .string("7"), nextCursor: "k1"),
            // conv_b moved while the pages were read: listed again, its first copy stays.
            "k1": CloudInboxList(entries: [Self.entry("conv_b", lastSeq: 9), Self.entry("conv_c")], revision: .string("8"), nextCursor: "k2"),
            "k2": CloudInboxList(entries: [Self.entry("conv_d")], revision: .string("9")),
        ])
        // The source's own daemon takes configure's background inbox read; `daemon` only allPages'.
        let source = CloudSourceHarness.connected(to: FakeCloudDaemon())
        let list = try await source.allPages(daemon, identity: Self.identity)
        #expect(list.entries.map(\.conversation) == ["conv_a", "conv_b", "conv_c", "conv_d"])
        #expect(list.entries.first { $0.conversation == "conv_b" }?.lastSeq == 1)
        #expect(list.revision == .string("7"))
        #expect(list.nextCursor == nil)
        let cursors = await daemon.inboxCursors
        #expect(cursors == [nil, "k1", "k2"])
    }

    @Test func aCursorThatDoesNotMoveEndsTheRead() async throws {
        let daemon = FakeCloudDaemon()
        await daemon.scriptInbox([
            "": CloudInboxList(entries: [Self.entry("conv_a")], nextCursor: "k1"),
            "k1": CloudInboxList(entries: [Self.entry("conv_b")], nextCursor: "k1"),
        ])
        // The source's own daemon takes configure's background inbox read; `daemon` only allPages'.
        let source = CloudSourceHarness.connected(to: FakeCloudDaemon())
        let list = try await source.allPages(daemon, identity: Self.identity)
        #expect(list.entries.map(\.conversation) == ["conv_a", "conv_b"])
        let cursors = await daemon.inboxCursors
        #expect(cursors == [nil, "k1"])
    }

    /// A later page that fails fails the read, so the store keeps its last whole list: a partial
    /// one would drop every conversation past the failed page.
    @Test func aLaterPagesFailureFailsTheRead() async throws {
        let daemon = FakeCloudDaemon()
        await daemon.scriptInbox(["": CloudInboxList(entries: [Self.entry("conv_a")], nextCursor: "k1")], failing: ["k1"])
        let source = CloudSourceHarness.connected(to: FakeCloudDaemon())
        await #expect(throws: (any Error).self) { _ = try await source.allPages(daemon, identity: Self.identity) }
    }

    /// An older daemon sends no cursor: its one page is the list.
    @Test func anOlderDaemonsOnePageIsTheList() async throws {
        let daemon = FakeCloudDaemon()
        await daemon.scriptInbox(["": CloudInboxList(entries: [Self.entry("conv_a")])])
        // The source's own daemon takes configure's background inbox read; `daemon` only allPages'.
        let source = CloudSourceHarness.connected(to: FakeCloudDaemon())
        let list = try await source.allPages(daemon, identity: Self.identity)
        #expect(list.entries.map(\.conversation) == ["conv_a"])
        let cursors = await daemon.inboxCursors
        #expect(cursors == [nil])
    }
}

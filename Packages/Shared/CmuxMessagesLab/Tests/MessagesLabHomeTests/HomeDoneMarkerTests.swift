import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// A Chief turn that says nothing posts a done marker: under its turn key, a message whose only
/// part is a done work part named by the turn's session (`optchat-b902d10e-816`), closing the
/// message it answers (optchat-chief brain/turns.rs). Home drew it as a bubble holding the session
/// name, under a faded quote of that message (2026-10-21). On the real view over a real HomeStore
/// it draws nothing, ends its turn's stream, and reading the chat reads it (`WorkRef.shownText`).
@MainActor @Suite(.serialized) struct HomeDoneMarkerTests {
    static let t = HomeChatRig.tag
    static let session = "\(t)optchat-b902d10e-816"
    static let marker = MessagePart.work(WorkRef(session: session, title: session, status: .done))

    /// The Chief posts the marker at the top level; an older one posted it in the thread of the
    /// message it closed. Neither draws.
    @Test(arguments: [false, true]) func doneMarkerShowsNoBubbleAndEndsItsStream(threaded: Bool) async throws {
        let rig = try await HomeChatRig()
        defer { rig.stop() }
        rig.view.projection.isVisibleToUser = true
        let asked = "\(Self.t)asked: launch the latest dev build"
        let askKey = IdempotencyKey("ask")
        #expect(await rig.post(asked, key: askKey))
        rig.frame()
        let root = try #require(rig.store.transcript(for: HomeChatRig.conversation).first { $0.key == askKey }?.messageID)

        let turn = IdempotencyKey("turn:optchat:816:1")
        rig.delta(turn.rawValue, seq: 0, "\(Self.t)checking")
        rig.frame()
        #expect(rig.bubbles() == [asked, "\(Self.t)checking"], "the turn streams")

        #expect(await rig.post([Self.marker], key: turn, threadRoot: threaded ? root : nil))
        rig.frame()
        #expect(rig.bubbles() == [asked], "no bubble for the marker, and its turn's stream ended")
        #expect(rig.view.controller.store?.state.ui.streams.isEmpty == true)

        // The marker is the newest message: reading the chat reads it too, or one unread stays for good.
        let markerSeq = try #require(rig.store.transcript(for: HomeChatRig.conversation).first { $0.key == turn }?.seq)
        await HomeChatRig.until { [store = rig.store, me = rig.me] in
            store.summary(HomeChatRig.conversation)?.readCursors[me] == markerSeq
        }
        #expect(rig.store.summary(HomeChatRig.conversation)?.readCursors[rig.me] == markerSeq)
    }

    /// A subagent's card (`work:<session>`) with a title of its own is content and still shows.
    @Test func aTitledSubagentCardStillShows() async throws {
        let rig = try await HomeChatRig()
        defer { rig.stop() }
        let title = "\(Self.t)Landed 3 commits"
        let card = MessagePart.work(WorkRef(session: Self.session, title: title, status: .done))
        #expect(await rig.post([card], key: IdempotencyKey("work:sess_1")))
        rig.frame()
        #expect(rig.bubbles() == [title])
    }
}

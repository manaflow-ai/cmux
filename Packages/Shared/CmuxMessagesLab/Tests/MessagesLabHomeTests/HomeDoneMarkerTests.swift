import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// A Chief turn that says nothing posts a done marker: a message whose only part is a done work
/// part named by the turn's session (`optchat-b902d10e-816`), in the thread of the message it
/// closes (optchat-chief brain/turns.rs). Home drew it as a bubble holding the session name, under
/// a faded quote of that message (2026-10-21). The real view over a real HomeStore shows no row for it.
@MainActor @Suite(.serialized) struct HomeDoneMarkerTests {
    static let t = HomeChatRig.tag
    static let session = "\(t)optchat-b902d10e-816"
    static let marker = MessagePart.work(WorkRef(session: session, title: session, status: .done))

    @Test func doneMarkerShowsNoBubbleAndEndsItsStream() async throws {
        let rig = try await HomeChatRig()
        defer { rig.stop() }
        let asked = "\(Self.t)asked: launch the latest dev build"
        let askKey = IdempotencyKey("ask")
        #expect(await rig.post(asked, key: askKey))
        rig.frame()
        let root = try #require(rig.store.transcript(for: HomeChatRig.conversation).first { $0.key == askKey }?.messageID)

        let turn = IdempotencyKey("turn:optchat:816:1")
        rig.delta(turn.rawValue, seq: 0, "\(Self.t)checking")
        rig.frame()
        #expect(rig.bubbles() == [asked, "\(Self.t)checking"], "the turn streams")

        #expect(await rig.post([Self.marker], key: turn, threadRoot: root))
        rig.frame()
        #expect(rig.bubbles() == [asked], "no bubble for the marker, and its turn's stream ended")
        let messages = rig.view.controller.store?.state.conversation.messages ?? []
        #expect(!messages.contains { $0.id == HomeMapping.rowSafe(turn.rawValue) }, "the marker is no row, so it quotes nothing")
        #expect(rig.view.controller.store?.state.ui.streams.isEmpty == true)
    }

    @Test func doneMarkerIsNoInboxPreview() {
        #expect(HomeMirror.previewText([Self.marker]).isEmpty)
        // A done card with a preview, or a running one, is real content and still shows.
        let withPreview = MessagePart.work(WorkRef(session: "s", title: "s", status: .done, preview: "Build 42 passed"))
        #expect(HomeMirror.previewText([withPreview]) == "Build 42 passed")
    }
}

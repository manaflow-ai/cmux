import AppKit
@testable import CmuxHomeCore
import Foundation
@testable import MessagesLabHome
import Testing

/// https://github.com/manaflow-ai/cmux/issues/41529: in an agent chat a new text slid down slowly and landed late,
/// drawing over the picture above it while it faded in. The chat has no entry motion: a received picture, the
/// text after it and my own sends (one line, and several: the field closes at once) show in their final place with their final opacity in the commit that adds them.
/// Checked on the real pane (`MessagesLabHomeView` over a `HomeStore`): the transcript commits no row motion
/// (MotionLedger), no container slide and no send flight.
@MainActor @Suite(.serialized) struct HomeEntryMotionTests {
    static let picture = AttachmentRef(hash: "hash_entry_motion", name: "shot.png", mimeType: "image/png",
                                       byteCount: 1_234, width: 400, height: 300)

    @Test func newRowsLandInPlaceWithNoMotion() async throws {
        let rig = try await HomeChatRig()
        defer { rig.stop() }
        rig.frame()
        let demo = try #require(rig.view.controller.demo)
        let motionsBefore = demo.ledger.entries.values.reduce(0) { $0 + $1.count }

        #expect(await rig.post([.attachment(Self.picture)], key: IdempotencyKey("k_entry_picture")))
        rig.frame()
        let text = "\(HomeChatRig.tag) the text after the picture"
        #expect(await rig.post(text, key: IdempotencyKey("k_entry_text")))
        rig.frame()
        #expect(await rig.send("\(HomeChatRig.tag) mine") == nil)
        rig.frame()

        let messages = try #require(rig.view.controller.store?.state.conversation.messages)
        let pictureID = try #require(messages.last { $0.parts.contains(where: Springs.isMedia) }?.id)
        let textID = try #require(messages.last { m in m.parts.contains { if case let .text(t, _) = $0 { t == text } else { false } } }?.id)
        let rows = demo.model.rows.map(\.spec.key)
        let pictureRows = rows.filter { RowBuilder.key($0, belongsTo: pictureID) }
        let textRows = rows.filter { RowBuilder.key($0, belongsTo: textID) }
        #expect(!pictureRows.isEmpty && !textRows.isEmpty, "rows: \(rows.suffix(8))")

        // No row of the new messages runs a slide, a fade or a grow, and nothing else started one.
        for key in pictureRows + textRows {
            #expect(demo.ledger.live(key).isEmpty, "\(key): \(demo.ledger.live(key).map { "\($0.target) \($0.keyPath)" })")
        }
        #expect(demo.ledger.entries.values.reduce(0) { $0 + $1.count } == motionsBefore)
        #expect(demo.containerMotionSprings.isEmpty, "container slides: \(demo.containerMotionSprings.map(\.spring))")
        #expect(demo.collection.layer.animationKeys()?.isEmpty ?? true)
        // My send shows in its row: no bubble flies from the field.
        #expect(demo.morphs.isEmpty)

        // A multi-line send shrinks the field at once: no spring on the field's glass and no send pulse,
        // so the rows that jumped never show under a field still closing (and no row moves either).
        #expect(await rig.send("\(HomeChatRig.tag) one\ntwo\nthree\nfour") == nil)
        rig.frame()
        #expect(demo.compose.glass.animationKeys()?.isEmpty ?? true, "field: \(demo.compose.glass.animationKeys() ?? [])")
        #expect(demo.morphs.isEmpty && demo.containerMotionSprings.isEmpty)
        #expect(demo.ledger.entries.values.reduce(0) { $0 + $1.count } == motionsBefore)

        // The text sits below the picture in its final layout, never over it. Row content bounds, not
        // `layout.frame(for:)`: a cell's frame adds the 24 pt shadow margin (RowDraw.margin) on both sides.
        func span(_ key: String) -> (top: CGFloat, bottom: CGFloat)? {
            guard let i = demo.model.index[key], let spec = demo.model.rows[checked: i]?.spec else { return nil }
            let top = demo.layout.contentTop(i)
            return (top, top + spec.height)
        }
        let pictureBottom = try #require(pictureRows.compactMap(span).map(\.bottom).max())
        let textTop = try #require(textRows.compactMap(span).map(\.top).min())
        #expect(textTop >= pictureBottom - 0.5, "text top \(textTop) over picture bottom \(pictureBottom)")
    }
}

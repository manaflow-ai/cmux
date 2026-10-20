import AppKit
import Testing
@testable import MessagesLabHome

/// A pasted picture in the Home composer can be taken out again (user report
/// 2026-10-19: hovering the picture showed no remove button, and Backspace
/// did not remove it).
@MainActor @Suite(.serialized) struct ComposeAttachmentRemoveTests {
    private func image(_ id: String) -> MessagesLabHome.Attachment {
        MessagesLabHome.Attachment(id: id, kind: "image", fileName: "\(id).png", mimeType: "image/png", byteSize: 1,
                   asset: "/tmp/\(id).png", poster: nil, width: 256, height: 128, durationSeconds: nil, transfer: .done)
    }

    private func state(_ attachments: [MessagesLabHome.Attachment]) -> MessagesLabHome.AppState {
        var s = MessagesLabHome.AppState(conversation: MessagesLabHome.Conversation(id: "c", title: "Chief", participants: [
            MessagesLabHome.Participant(id: "me", displayName: "Me", isMe: true, avatar: nil),
        ], messages: []))
        s.ui.draft.attachments = attachments
        return s
    }

    private func field(_ text: String, caret: NSRange) -> FieldTextView {
        let tv = FieldTextView(usingTextLayoutManager: true)
        tv.isRichText = false
        tv.string = text
        tv.setSelectedRange(caret)
        return tv
    }

    /// The host rebuilds its hover tracking area from `fieldRect` when the
    /// attachments change, so the field must already have the picture row's
    /// height then; with the one-line rect the picture was outside the area.
    @Test func attachmentsChangeAfterTheFieldTakesTheirRow() throws {
        let compose = ComposeView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        var seen: CGRect?
        compose.onAttachmentsChanged = { seen = compose.fieldRect }
        compose.update(state: state([image("a")]), send: false, begin: 0)
        let rect = try #require(seen)
        #expect(rect == compose.fieldRect)
        #expect(rect.height >= compose.strip.height + ComposeMetrics.oneLine - 0.5)
        let tile = try #require(compose.strip.tiles.first).rect
        #expect(rect.contains(CGPoint(x: rect.minX + tile.midX, y: rect.minY + tile.midY)))
    }

    @Test func backspaceAtTheStartRemovesAnAttachment() {
        let tv = field("hi", caret: NSRange(location: 0, length: 0))
        var asked = 0
        tv.onDeleteAtStart = { asked += 1; return true }
        tv.deleteBackward(nil)
        #expect(asked == 1)
        #expect(tv.string == "hi")
    }

    @Test func backspaceAfterTextDeletesText() {
        let tv = field("hi", caret: NSRange(location: 2, length: 0))
        var asked = 0
        tv.onDeleteAtStart = { asked += 1; return true }
        tv.deleteBackward(nil)
        #expect(asked == 0)
        #expect(tv.string == "h")
    }

    @Test func backspaceOnASelectionAtTheStartDeletesTheSelection() {
        let tv = field("hi", caret: NSRange(location: 0, length: 1))
        var asked = 0
        tv.onDeleteAtStart = { asked += 1; return true }
        tv.deleteBackward(nil)
        #expect(asked == 0)
        #expect(tv.string == "i")
    }
}

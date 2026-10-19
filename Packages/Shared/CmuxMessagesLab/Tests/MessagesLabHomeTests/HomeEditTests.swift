import AppKit
import CmuxHomeCore
import CmuxHomeRender
import Testing
@testable import MessagesLabHome

/// Edit on my message in Home (Lawrence 2026-10-19: "You can now edit
/// previous messages within a thread in the desktop app [Codex]... make sure
/// to implement this for us too"): the message menu's Edit and Up in an empty
/// field open MessagesLab's inline editor over my bubble with the message's
/// text; Return gives the new text to the host (`ChatIntents.edit`), Esc or
/// a click off it cancels. Drives a real `ChatController` over a loaded
/// conversation in an offscreen window, with a recording host.
@MainActor @Suite(.serialized) struct HomeEditTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    /// The host side: which messages edit, with what text, and the edits saved.
    final class Intents: ChatIntents {
        var editable: [ID: String] = [:]
        var edits: [(ID, String)] = []
        func editableText(_ id: ID) -> String? { editable[id] }
        func edit(_ id: ID, text: String) { edits.append((id, text)) }
        func threadMovedByUser() {}
        func messageLink(_ id: ID) -> String? { nil }
        func send() -> String? { nil }
        func react(_ ref: PartRef, _ kind: Reaction.Kind) {}
        var canReact: Bool { false }
        var canReply: Bool { false }
        func pickAttachments() {}
        func takeAttachments(from pasteboard: NSPasteboard) -> Bool { false }
        func acceptsAttachments(from pasteboard: NSPasteboard) -> Bool { false }
        func statusLineClicked(_ rect: CGRect, in view: NSView) {}
        func draftChanged() {}
        func linkTapped(_ ref: PartRef, url: String) {}
        func canCancelSend(_ message: ID) -> Bool { false }
        func cancelSend(_ message: ID) {}
        func openAttachment(_ message: ID, _ attachment: ID) {}
        func toggleVideo(_ ref: PartRef, _ attachment: ID) {}
        func videoState(_ ref: PartRef) -> HomeVideoState { .poster }
        func scrolled() {}
        func rowsPlaced() {}
    }

    struct Pane {
        let window: NSWindow
        let controller: ChatController
        let intents: Intents
        var field: FieldTextView { controller.demo!.compose.textView.view }
    }

    static let me = ParticipantID("user_me")
    static let them = ParticipantID("agent_chief")
    static func text(_ i: Int) -> String { "Message number \(i) with a few words" }

    private func pane() -> Pane {
        let people = [CmuxHomeCore.Participant(id: Self.me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: Self.them, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let items = (1...6).map { i in
            TranscriptItem(key: IdempotencyKey("k\(i)"), seq: Seq(i), author: i % 2 == 0 ? Self.me : Self.them,
                           parts: [.text(Self.text(i))], createdAt: base.addingTimeInterval(Double(i)),
                           delivery: .committed, messageID: MessageID("msg_\(i)"))
        }
        let summary = ConversationSummary(id: ConversationID("conv_edit"), title: "Chief", participants: people, lastSeq: 6,
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        var core = ProjectionCore(me: Self.me)
        let (conv, w) = core.install(ConversationID("conv_edit"), items: items, summary: summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 600, height: 700)), wake: NoWake())
        let intents = Intents()
        controller.intents = intents
        window.contentView = controller.host
        controller.install(conv, windowStart: w.start, total: w.total)
        controller.host.layoutSubtreeIfNeeded()
        return Pane(window: window, controller: controller, intents: intents)
    }

    private func mine(_ p: Pane) throws -> MessagesWindowView.Hit {
        try #require(p.controller.demo?.lastTextRow(mine: true))
    }

    private func titles(_ p: Pane, at hit: MessagesWindowView.Hit) -> [String] {
        p.controller.menu(at: CGPoint(x: hit.body.midX, y: hit.body.midY))?.items.map(\.title) ?? []
    }

    @Test func myMessageTheHostEditsHasEditInItsMenu() throws {
        let p = pane()
        let hit = try mine(p)
        #expect(!titles(p, at: hit).contains(Strings.menuEdit))
        p.intents.editable[hit.row.ref.messageId] = Self.text(6)
        #expect(titles(p, at: hit).contains(Strings.menuEdit))
        // Never on theirs, whatever the host says.
        let theirs = try #require(p.controller.demo?.lastTextRow(mine: false))
        p.intents.editable[theirs.row.ref.messageId] = Self.text(5)
        #expect(!titles(p, at: theirs).contains(Strings.menuEdit))
    }

    @Test func returnSavesTheNewTextThroughTheHost() throws {
        let p = pane()
        let hit = try mine(p)
        let id = hit.row.ref.messageId
        p.intents.editable[id] = "The whole text of the message"
        p.controller.beginEdit(hit)
        let editor = try #require(p.controller.editor)
        // The message's whole text from the host, not the bubble's.
        #expect(editor.textView.string == "The whole text of the message")
        editor.textView.string = "Edited words"
        editor.textView.onSend()
        #expect(p.intents.edits.map(\.0) == [id])
        #expect(p.intents.edits.map(\.1) == ["Edited words"])
        #expect(p.controller.editor == nil)
        #expect(editor.superview == nil)
        #expect(p.window.firstResponder === p.field)
    }

    @Test func escapeAndAClickOffItCancel() throws {
        let p = pane()
        let hit = try mine(p)
        p.intents.editable[hit.row.ref.messageId] = Self.text(6)
        p.controller.beginEdit(hit)
        try #require(p.controller.editor).textView.onEscape()
        #expect(p.controller.editor == nil)
        p.controller.beginEdit(hit)
        #expect(p.controller.editor != nil)
        p.controller.clicked(CGPoint(x: 300, y: 300))
        #expect(p.controller.editor == nil)
        #expect(p.intents.edits.isEmpty)
    }

    @Test func upInAnEmptyFieldEditsMyLastMessage() throws {
        let p = pane()
        let up = #selector(NSResponder.moveUp(_:))
        // Nothing the host edits: Up moves the caret as before.
        #expect(!p.controller.textView(p.field, doCommandBy: up))
        let last = try mine(p).row.ref.messageId
        p.intents.editable[last] = Self.text(6)
        #expect(p.controller.textView(p.field, doCommandBy: up))
        #expect(p.controller.editor?.textView.string == Self.text(6))
        p.controller.closeEditor()
        // Typed text keeps Up for the caret.
        p.field.string = "a draft"
        #expect(!p.controller.textView(p.field, doCommandBy: up))
        #expect(p.controller.editor == nil)
    }

    @Test func anEditedMessageSaysEditedAfterARebuild() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var item = TranscriptItem(key: IdempotencyKey("k1"), seq: Seq(1), author: Self.me, parts: [.text("hi")],
                                  createdAt: base, delivery: .committed, messageID: MessageID("msg_1"))
        #expect(HomeMapping.edits(item) == nil)
        item.editedAt = base.addingTimeInterval(60)
        #expect(HomeMapping.edits(item)?.count == 1)
        item.isRetracted = true
        #expect(HomeMapping.edits(item) == nil)
    }
}

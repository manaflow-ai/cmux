// cmux: Edit on my message (Lawrence 2026-10-19: "You can now edit previous
// messages within a thread in the desktop app [Codex]... make sure to
// implement this for us too"). MessagesLab's Edit (appkit-native Host.swift
// beginEdit/closeEditor, not vendored) with the edit going to HomeStore
// (`intents.edit`, `HomeOp.editMessage`), never to the projection: the bubble
// changes when the edited message comes back (HomeDiff's `.edit`, "Edited"
// under it). The message menu's Edit and Up in an empty field open it; Return
// saves, Esc or a click outside cancels. Not a vendored file.
import AppKit

extension ChatController {
    /// Opens the inline editor over `hit`'s bubble with the whole text of its
    /// message (a text Messages' link rule shows as several bubbles edits as one).
    func beginEdit(_ hit: MessagesWindowView.Hit) {
        closeEditor(refocus: false)
        let id = hit.row.ref.messageId
        guard let text = intents?.editableText(id) else { return }
        let e = InlineEditor(text: text, frame: hit.body, maxX: host.bounds.width - 20) { [weak self] newText in
            self?.intents?.edit(id, text: newText)
            self?.closeEditor()
        } cancel: { [weak self] in self?.closeEditor() }
        // MessagesLab's editor fill is its dark field grey; a light theme gets the incoming
        // bubble's grey under its dark text (ComposeView.typing is Fixture.incomingText).
        if Fixture.lightAppearance { e.layer?.backgroundColor = Fixture.incoming.cgColor }
        host.addSubview(e, positioned: .below, relativeTo: host.above)
        editor = e
        if !Self.noFocus { window?.makeFirstResponder(e.textView) }
    }

    /// Closes the editor without saving; the field takes the keyboard back.
    func closeEditor(refocus: Bool = true) {
        guard let e = editor else { return }
        e.removeFromSuperview()
        editor = nil
        if refocus { focusCompose() }
    }

    /// Up in an empty field (no text, no chips, no composition): edits my newest
    /// message the owner can take an edit of, in the open thread view or the
    /// transcript (Messages and Codex). False, and Up moves the caret as before,
    /// when there is none.
    func editLastMessage() -> Bool {
        guard let demo, let store, editor == nil, picker == nil else { return false }
        let field = demo.compose.textView.view
        guard field.string.isEmpty, !field.hasMarkedText(), store.state.ui.draft.attachments.isEmpty else { return false }
        let me = store.state.me
        for m in store.state.conversation.messages.reversed().prefix(200) where m.senderId == me && m.retractedAt == nil {
            guard intents?.editableText(m.id) != nil else { continue }
            // On screen as it is, else scrolled into view (a thread view shows only its thread's
            // messages: then the next one).
            guard let hit = editHit(m.id) ?? (demo.revealHostMessage(m.id, highlight: false) ? editHit(m.id) : nil) else { continue }
            beginEdit(hit)
            return editor != nil
        }
        return false
    }

    /// The drawn text bubble of message `id` (its first), as a click on it would hit.
    func editHit(_ id: ID) -> MessagesWindowView.Hit? {
        guard let demo else { return nil }
        if demo.threadOpen {
            for (v, spec) in zip(demo.threadViews, demo.threadSpecs) {
                guard case let .part(row) = spec.kind, row.ref.messageId == id, row.part.plainText != nil else { continue }
                let body = RowDraw.bodyRect(spec).offsetBy(dx: v.frame.minX, dy: v.frame.minY)
                let outline = RowDraw.balloon(RowDraw.bodyRect(spec), row: row, scale: demo.renderScale).offsetBy(dx: v.frame.minX, dy: v.frame.minY)
                return MessagesWindowView.Hit(row: row, body: body, key: spec.key, outline: outline)
            }
            return nil
        }
        let cells = demo.collection.visibleCells.compactMap { $0 as? RowCell }
        for cell in cells {
            guard let spec = cell.spec, case let .part(row) = spec.kind, row.ref.messageId == id, row.part.plainText != nil else { continue }
            let body = cell.convert(RowDraw.bodyRect(spec), to: demo)
            let outline = cell.convert(RowDraw.balloon(RowDraw.bodyRect(spec), row: row, scale: demo.renderScale), to: demo)
            return MessagesWindowView.Hit(row: row, body: body, key: spec.key, outline: outline)
        }
        return nil
    }
}

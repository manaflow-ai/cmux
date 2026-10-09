import AppKit

/// The pane controller's clicks, from MessagesLab 2579028's Host.swift (not
/// vendored) over the vendored TranscriptSelection: shift-click extends the
/// selection, a double press selects the word and a triple press the
/// paragraph (a drag then extends by that unit), a press on the highlight
/// drags the text out, and a click on a bubble selects that message. The
/// differences from Host.swift are marked `cmux:`.
extension ChatController {
    func mouseDown(at p: CGPoint, _ e: NSEvent) {
        if let tv = demo?.compose.textView.view, demo?.compose.fieldRect.contains(p) == true { window?.makeFirstResponder(tv); return }
        if e.clickCount == 1, e.modifierFlags.contains(.shift), !selection.isEmpty {
            // Shift-click extends the selection (SELECTION.md).
            selection.mouseDown(p, shift: true)
        } else if e.clickCount >= 3 {
            // Triple click: the paragraph; a drag then extends by paragraphs.
            selection.mouseDown(p, count: 3)
            if !selection.isEmpty { window?.makeFirstResponder(host.scrollView.document) }
        } else if e.clickCount == 1 {
            selection.mouseDown(p)
            // Press and hold on a message opens the tapback picker (MessagesLab 7f1a811); the
            // picker takes the selection off. cmux: only while the owner takes tapbacks.
            if picker == nil, intents?.canReact == true, let hit = demo?.hit(p) {
                hold.start(at: p) { [weak self] in
                    self?.selection.clear()
                    self?.showPicker(for: hit)
                }
            }
        } else if e.clickCount == 2 {
            // Real Messages selects the word on the second press, not on its release; the
            // first click's bubble selection fades out then.
            selection.deselectBubble()
            doubleClicked(p)
        }
    }

    func mouseDragged(at p: CGPoint, _ e: NSEvent) {
        hold.moved(to: p)
        let doc = host.scrollView.document
        // The selection runs its own autoscroll past the transcript's edges (SELECTION.md).
        if selection.mouseDragged(p, event: e), window?.firstResponder !== doc, !selection.textDragging { window?.makeFirstResponder(doc) }
    }

    func mouseUp(at p: CGPoint, _ e: NSEvent) {
        let held = hold.fired
        hold.cancel()
        if held { return }
        if selection.mouseUp() { return }
        if e.clickCount == 1 { clicked(p) }
    }

    func clicked(_ p: CGPoint) {
        guard let demo else { return }
        if picker != nil { closePicker(); return }
        if let id = demo.compose.chip(at: p) { dispatch(.removeDraftAttachment(id)); return }
        guard p.y > Fixture.headerHeight, !demo.compose.fieldRect.insetBy(dx: 0, dy: -2).contains(p) else { return }
        if demo.longTextBandHit(p) { return }    // "Show all N lines" on a folded long message
        guard let hit = demo.hit(p) else {
            selection.deselectBubble()
            // cmux: a click on empty transcript space gives the field the keyboard.
            focusCompose()
            return
        }
        selection.selectBubble(hit.key, outgoing: hit.row.outgoing)
        focusTranscript()
        // cmux: a link (re-checked at click time, MarkdownLinkPolicy) opens in PaneLinks.
        if openLink(hit, at: p) { return }
        switch hit.row.part {
        // cmux: the bytes come from HomeStore (Host.swift opened a fixture asset); a video
        // plays or pauses in its bubble (opening it in an app is in the context menu).
        case let .attachment(a) where a.kind == "video": intents?.toggleVideo(hit.row.ref, a.id)
        case let .attachment(a): intents?.openAttachment(hit.row.ref.messageId, a.id)
        default: break
        }
    }

    /// Real Messages (click references): a click on a bubble takes the focus from the
    /// field, so Copy copies the selected message.
    private func focusTranscript() {
        guard !Self.noFocus else { return }
        let doc = host.scrollView.document
        doc.takesFocus = true
        window?.makeFirstResponder(doc)
        doc.takesFocus = false
    }

    /// Real Messages: a double-click on a bubble selects the word under the
    /// cursor (the picker is press and hold); a drag then extends by words.
    func doubleClicked(_ p: CGPoint) {
        guard demo?.hit(p) != nil else { return }
        selection.mouseDown(p, count: 2)
        if !selection.isEmpty { window?.makeFirstResponder(host.scrollView.document) }
    }

    // MARK: Drops

    // cmux: files and pictures go to the host's intake (types only while dragging); plain
    // text over the field (a text drag out of the transcript) goes into the field.
    func dragEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        intents?.acceptsAttachments(from: sender.draggingPasteboard) == true ? .copy : textDropOperation(sender)
    }

    func performDrop(_ sender: NSDraggingInfo) -> Bool {
        if textDropOperation(sender) == .copy { return performTextDrop(sender) }
        return intents?.takeAttachments(from: sender.draggingPasteboard) ?? false
    }
}

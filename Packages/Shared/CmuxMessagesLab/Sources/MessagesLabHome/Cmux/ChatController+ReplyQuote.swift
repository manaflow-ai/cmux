// cmux: Reply to Selection (plans/cmux-next/reply-to-selection-DESIGN.md). Not a vendored file.
import AppKit

/// Reply to Selection: the menu item, the card on the message box, the quote a
/// send carries, and a click on a sent quote showing its words in the original.
extension ChatController {
    // MARK: The menu item

    /// The quote a right-click at `hit` offers: the transcript selection, when all of it is in
    /// that bubble's message. Nil: no selection, or it reaches another message.
    func selectionQuote(at hit: MessagesWindowView.Hit) -> ReplyQuote? {
        guard !selection.isEmpty else { return nil }
        let ranges = selection.selectedRanges()
        guard ranges.contains(where: { RowBuilder.key($0.key, belongsTo: hit.row.ref.messageId) }) else { return nil }
        return ReplyQuote(selection: ranges, messageId: hit.row.ref.messageId, partIndex: hit.row.ref.partIndex)
    }

    /// The quote of the transcript selection wherever it is (the keyboard and palette path): nil
    /// when nothing is selected or the selection spans messages.
    func selectionQuote() -> ReplyQuote? {
        guard !selection.isEmpty, let first = selection.selectedRanges().first,
              case let .part(row)? = rowSpec(first.key)?.kind else { return nil }
        return ReplyQuote(selection: selection.selectedRanges(), messageId: row.ref.messageId, partIndex: row.ref.partIndex)
    }

    /// Reply to Selection: the thread composer opens as Reply… does, with the quote on the field.
    func replyToSelection(_ quote: ReplyQuote) {
        // Validate the capability before mutating the engine, selection, or focus.
        guard intents?.canReply == true,
              intents?.canInteract(with: quote.source.messageId) != false else { return }
        dispatch(.reply(quote.source))
        replyQuote = quote
        selection.clear()
        focusCompose()
    }

    /// Thread changes that end the reply the quote belongs to: closing the thread, another Reply….
    func forgetQuote(for a: Action) {
        guard replyQuote != nil else { return }
        switch a {
        case .closeThread, .openThreadPath: replyQuote = nil
        case let .reply(ref) where ref != replyQuote?.source: replyQuote = nil
        default: break
        }
    }

    // MARK: The card on the message box

    func updateQuoteCard() {
        guard let quote = replyQuote else {
            host.hideQuoteCard()
            return
        }
        let sender = store?.state.conversation.messages.first { $0.id == quote.source.messageId }?.senderId
        let name = sender.flatMap { id in store?.state.conversation.participants.first { $0.id == id }?.displayName }
        host.showQuoteCard(quote, from: name) { [weak self] in
            self?.replyQuote = nil
            self?.focusCompose()
        }
        placeQuoteCard()
    }

    func placeQuoteCard() {
        guard let demo else { return }
        host.placeQuoteCard(above: demo.compose.fieldRect)
    }

    // MARK: Sending

    /// The text a send gives the owner: the quote as a Markdown blockquote above the reply.
    func quotedForSend(_ text: String) -> String {
        replyQuote.map { $0.quoted(reply: text) } ?? text
    }

    /// The local bubble's text before the owner has it (the field's draft with the quote's head),
    /// so the bubble shows the quote from the send on, as HomeMapping shows the stored reply.
    func shownDraftForSend(_ draft: String) -> String? {
        guard let quote = replyQuote else { return nil }
        return ReplyQuote.head(quote.text).text + "\n" + draft
    }

    // MARK: A click on a sent quote

    /// A click on the quote at the top of a reply: the original's quoted words flash (the
    /// original scrolls into view first). True when the click was on a quote.
    func quoteClicked(_ hit: MessagesWindowView.Hit, at p: CGPoint) -> Bool {
        guard case let .text(text, runs) = hit.row.part,
              let run = runs.first(where: { $0.start == 0 && $0.style?.contains("quote") == true }),
              let spec = rowSpec(hit.key), let g = TranscriptSelection.geometry(spec) else { return false }
        let offset = TranscriptSelection.position(at: p, body: hit.body, key: hit.key, geometry: g).offset
        guard offset <= run.length else { return false }
        let head = (text as NSString).substring(with: NSRange(location: 0, length: min(run.length, (text as NSString).length)))
        let words = head.trimmingCharacters(in: CharacterSet(charactersIn: "\u{201C}\u{201D}"))
        guard let message = store?.state.conversation.messages.first(where: { $0.id == hit.row.ref.messageId }) else { return false }
        // The message answered: the tree parent, else the thread root, else the newest earlier message holding the words.
        var candidates: [ID] = [message.parent?.messageId, message.replyTo?.messageId].compactMap { $0 }
        if let all = store?.state.conversation.messages, let i = all.firstIndex(where: { $0.id == message.id }) {
            candidates += all.prefix(i).reversed().map(\.id)
        }
        for id in candidates where id != message.id {
            if demo?.flashQuote(words, in: id) == true { return true }
        }
        return true
    }

    private func rowSpec(_ key: String) -> RowSpec? {
        guard let demo else { return nil }
        if demo.threadOpen { return demo.threadSpecs.first { $0.key == key } }
        guard let i = demo.model.index.value(for: key) else { return nil }
        return demo.model.rows[checked: i]?.spec
    }
}

extension MessagesWindowView {
    /// Shows message `id` (`revealHostMessage`) and flashes `words` in it with the system find
    /// highlight. False when the message is not shown or does not hold the words.
    func flashQuote(_ words: String, in id: ID) -> Bool {
        var targets: [(layer: CALayer, body: CGRect, spec: RowSpec)] = []
        func collect() {
            targets = []
            if threadOpen {
                for (v, spec) in zip(threadViews, threadSpecs) where RowBuilder.key(spec.key, belongsTo: id) {
                    targets.append((v.layer, RowDraw.bodyRect(spec), spec))
                }
            } else {
                for case let cell as RowCell in collection.visibleCells {
                    guard let spec = cell.spec, RowBuilder.key(spec.key, belongsTo: id) else { continue }
                    let body = cell.convert(RowDraw.bodyRect(spec), to: collection).offsetBy(dx: cell.rowSnap.x, dy: cell.rowSnap.y)
                    targets.append((collection.layer, body, spec))
                }
            }
        }
        // Only a message that holds the words scrolls into view.
        guard model.rows.contains(where: { RowBuilder.key($0.spec.key, belongsTo: id) && Self.quoteRange(words, $0.spec) != nil })
                || threadSpecs.contains(where: { RowBuilder.key($0.key, belongsTo: id) && Self.quoteRange(words, $0) != nil }),
              revealHostMessage(id, highlight: false) else { return false }
        collect()
        var flashed = false
        for t in targets {
            guard let g = TranscriptSelection.geometry(t.spec), let range = Self.quoteRange(words, t.spec) else { continue }
            let rects = TranscriptSelection.highlightRects(range, body: t.body, geometry: g, visible: -1e9...1e9)
            guard !rects.isEmpty else { continue }
            flashRanges(rects, in: t.layer)
            flashed = true
        }
        return flashed
    }

    private static func quoteRange(_ words: String, _ spec: RowSpec) -> NSRange? {
        guard let g = TranscriptSelection.geometry(spec) else { return nil }
        return ReplyQuote.locate(words, in: g.substring(NSRange(location: 0, length: g.length)))
    }

    /// The system find highlight over `rects`, with the permalink reveal's timing (in, hold, out).
    private func flashRanges(_ rects: [CGRect], in container: CALayer) {
        let path = CGMutablePath()
        for r in rects { path.addRoundedRect(in: r.insetBy(dx: -1.5, dy: -0.5), cornerWidth: 3, cornerHeight: 3) }
        let l = CAShapeLayer()
        l.name = "cmux.replyQuoteFlash"
        l.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(), "opacity": NSNull()]
        l.path = path
        l.fillColor = NSColor.findHighlightColor.withAlphaComponent(0.5).cgColor
        l.zPosition = 1_000_000_000
        // The render server skips a layer whose model opacity is exactly 0; the layer leaves at the end.
        l.opacity = 0.01
        let total = Self.revealIn + Self.revealHold + Self.revealOut
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [0, 1, 1, 0]
        a.keyTimes = [0, Self.revealIn / total, (Self.revealIn + Self.revealHold) / total, 1].map { NSNumber(value: $0) }
        a.duration = total
        CATransaction.begin()
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        container.addSublayer(l)
        l.add(a, forKey: "quote")
        CATransaction.commit()
    }
}

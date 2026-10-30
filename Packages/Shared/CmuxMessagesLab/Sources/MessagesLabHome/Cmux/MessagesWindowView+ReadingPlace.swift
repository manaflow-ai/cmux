import AppKit

/// cmux (#27627): the person's place in a transcript, by message, so a new view of the same chat
/// opens where they left it (Messages: a conversation opens at its newest message, or where it was
/// left scrolled up). The place is the newest message with a row on screen and how far its last row's
/// bottom sits above the transcript's bottom edge (`anchorY`), as `HomeScrollAnchor` keeps it.
extension MessagesWindowView {
    /// Where the person reads: the engine id of the newest message on screen and its offset; nil with
    /// no rows or when the transcript shows its newest message at the bottom.
    var readingPlace: (message: String, offset: CGFloat)? {
        guard model.count > 0, !(store.state.ui.scroll.pinnedToBottom && store.state.atNewest) else { return nil }
        var i = firstVisibleRow
        while i + 1 < model.count, windowY(contentY: layout.contentTop(i + 1)) < anchorY { i += 1 }
        guard let id = model.rows[checked: i].flatMap({ Self.message(ofRow: $0.spec.key) }), // checked
              let last = lastRow(of: id) else { return nil }
        return (id, anchorY - windowY(contentY: rowBottom(last)))
    }

    /// Scrolls so message `id`'s last row sits `offset` above the transcript's bottom edge, within
    /// the loaded rows (at the bottom it is pinned again). False when no row of `id` is loaded.
    @discardableResult
    func show(message id: String, offset: CGFloat, in scrollView: TranscriptScrollView) -> Bool {
        guard let last = lastRow(of: id) else { return false }
        let y = rowBottom(last) + MessagesWindowView.cvTop - (anchorY - offset)
        let clamped = min(max(y, minOffset), pinnedOffset)
        if clamped >= pinnedOffset - 0.5, store.state.atNewest {
            pinToBottom()
        } else {
            store.dispatch(.setScroll(offset: pinnedOffset - clamped, pinned: false))
            scrollView.scroll(toModelOffset: clamped)
            userScrolled()
        }
        return true
    }

    /// Some rows still carry estimated heights (a width change's measure is coming).
    var hasEstimatedRows: Bool { model.rows.contains { $0.spec.estimated } }

    private func rowBottom(_ i: Int) -> CGFloat {
        layout.contentTop(i) + (model.rows[checked: i]?.spec.height ?? 0) // checked
    }

    private func lastRow(of id: String) -> Int? {
        model.rows.lastIndex { !$0.ghost && RowBuilder.key($0.spec.key, belongsTo: id) }
    }

    /// The message a row key names ("kind:messageID[:part]"); nil for rows of no message.
    private static func message(ofRow key: String) -> String? {
        let parts = key.split(separator: ":", maxSplits: 2)
        return parts.count >= 2 ? String(parts[1]) : nil
    }
}

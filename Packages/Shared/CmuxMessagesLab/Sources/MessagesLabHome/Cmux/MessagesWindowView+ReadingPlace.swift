import AppKit

/// cmux (#27627): the person's place in a transcript, by message, so a new view of the same chat
/// opens where they left it (Messages: a conversation opens at its newest message, or where it was
/// left scrolled up). The place is the newest message with a bubble on screen and how far its last
/// bubble's bottom sits above the transcript's bottom edge (`anchorY`), as `HomeScrollAnchor` keeps
/// it. Bubbles only: a receipt, edited or replies line under a message comes and goes between views.
extension MessagesWindowView {
    /// Where the person reads: the engine id of the newest message on screen that `keeps` accepts,
    /// and its offset; nil with no such message or when the transcript shows its newest message.
    func readingPlace(keeps: (String) -> Bool) -> (message: String, offset: CGFloat)? {
        guard model.count > 0, !(store.state.ui.scroll.pinnedToBottom && store.state.atNewest) else { return nil }
        var i = firstVisibleRow
        while i + 1 < model.count, windowY(contentY: layout.contentTop(i + 1)) < anchorY { i += 1 }
        // Back from the bottom edge to a kept message's bubble (past typing dots, a notice, a
        // fading row, a running reply's stream).
        while i >= 0 {
            if let row = model.rows[checked: i], !row.ghost, let id = Self.bubbleMessage(ofRow: row.spec.key), keeps(id), // checked
               let last = lastBubble(of: id) {
                return (id, anchorY - windowY(contentY: rowBottom(last)))
            }
            i -= 1
        }
        return nil
    }

    /// Scrolls so message `id`'s last bubble sits `offset` above the transcript's bottom edge, within
    /// the loaded rows (at the bottom it is pinned again). False when no bubble of `id` is loaded.
    @discardableResult
    func show(message id: String, offset: CGFloat, in scrollView: TranscriptScrollView) -> Bool {
        guard let last = lastBubble(of: id) else { return false }
        let y = rowBottom(last) + MessagesWindowView.cvTop - (anchorY - offset)
        let clamped = min(max(y, minOffset), pinnedOffset)
        if clamped >= pinnedOffset - 0.5, store.state.atNewest {
            pinToBottom()
            scrollView.syncFromModel()
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

    private func lastBubble(of id: String) -> Int? {
        model.rows.lastIndex { !$0.ghost && Self.bubbleMessage(ofRow: $0.spec.key) == id }
    }

    /// The message a bubble row names ("part:messageID:index"); nil for any other row.
    private static func bubbleMessage(ofRow key: String) -> String? {
        let parts = key.split(separator: ":", maxSplits: 2)
        return parts.count >= 2 && parts[0] == "part" ? String(parts[1]) : nil
    }
}

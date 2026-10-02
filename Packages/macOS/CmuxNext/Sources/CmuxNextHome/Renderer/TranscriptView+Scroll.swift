import AppKit

extension TranscriptView {
    /// Screen y (y-down points) of the content top: pinned puts the newest row
    /// on the viewport bottom, otherwise the anchor row sits at its recorded
    /// top. Clamped at the oldest and newest ends of the conversation.
    func contentBase() -> CGFloat {
        let bottomBase = viewportBottom - geometry.bottomPadding - rowLayout.totalHeight
        guard !anchor.pinned, let key = anchor.key else { return bottomBase }
        var base = rowLayout.rowIndex(of: key).map { anchor.top - rowLayout.tops[$0] } ?? lastBase
        if !history.hasOlder { base = min(base, 0) }
        if history.atNewest { base = max(base, bottomBase) }
        return base
    }

    /// Scrolls by `dy` points (positive = toward older), then pages if needed.
    func scroll(by dy: CGFloat) {
        if !pendingOlder.isEmpty || !pendingNewer.isEmpty { applyPageChunk() }
        scrollVelocity = dy
        anchor = scrolled(by: dy)
        render()
    }

    /// The anchor after scrolling by `dy`: the first row reaching the
    /// viewport top and its screen y, or pinned when the newest row reached the bottom.
    func scrolled(by dy: CGFloat) -> TranscriptAnchor {
        guard !rowLayout.isEmpty else { return TranscriptAnchor() }
        let bottomBase = viewportBottom - geometry.bottomPadding - rowLayout.totalHeight
        var base = (anchor.pinned ? bottomBase : lastBase) + dy
        if !history.hasOlder { base = min(base, 0) }
        if history.atNewest, base <= bottomBase + 0.5 { return TranscriptAnchor() }
        let index = min(rowLayout.rows.count - 1, rowLayout.firstRow(endingAtOrBelow: -base))
        return TranscriptAnchor(pinned: false, key: rowLayout.rows[index].key, top: base + rowLayout.tops[index])
    }

    /// Window message indexes on screen (paging decisions).
    func visibleMessageRange() -> ClosedRange<Int>? {
        guard !rowLayout.isEmpty else { return nil }
        let first = min(rowLayout.rows.count - 1, rowLayout.firstRow(endingAtOrBelow: -lastBase))
        let last = max(first, min(rowLayout.rows.count - 1, rowLayout.firstRow(startingBelow: viewportBottom - lastBase) - 1))
        guard let lo = rowLayout.messageIndex(ofRow: first), let hi = rowLayout.messageIndex(ofRow: last) else { return nil }
        return lo...max(lo, hi)
    }

    /// Seq of the oldest message on screen (bench).
    var seqAtTop: Int {
        guard let range = visibleMessageRange(), range.lowerBound < history.count else { return history.firstSeq }
        return history[range.lowerBound].seq ?? history.lastSeq
    }

    var isPinned: Bool { anchor.pinned }

    /// Jumps to the oldest message: loads only its first rows and anchors the first row at the top.
    func jumpToOldest(completion: (@MainActor () -> Void)? = nil) {
        guard let source else { return }
        if !history.hasOlder {
            anchorAtTop()
            completion?()
            return
        }
        generation += 1
        let expected = generation
        let oldest = history.oldestAvailable
        Task { @MainActor [weak self] in
            let page = (try? await source.page(before: oldest + Self.jumpSize, limit: Self.jumpSize)) ?? []
            guard let self, self.generation == expected else { return }
            let measured = await self.measureOffMain(page)
            guard self.generation == expected else { return }
            self.replaceWindow(measured, pending: source.pendingMessages)
            self.anchorAtTop()
            self.render()
            completion?()
        }
    }

    /// Jumps to the newest message, pinned; loads the newest rows when the window is elsewhere.
    func jumpToNewest(completion: (@MainActor () -> Void)? = nil) {
        guard let source, !history.atNewest else {
            anchor = TranscriptAnchor()
            render()
            completion?()
            return
        }
        generation += 1
        let expected = generation
        let newest = source.newestSeq ?? 0
        Task { @MainActor [weak self] in
            let page = (try? await source.page(before: newest + 1, limit: Self.jumpSize)) ?? []
            guard let self, self.generation == expected else { return }
            let measured = await self.measureOffMain(page)
            guard self.generation == expected else { return }
            self.replaceWindow(measured, pending: source.pendingMessages)
            self.anchor = TranscriptAnchor()
            self.render()
            completion?()
        }
    }

    private func anchorAtTop() {
        guard let first = rowLayout.rows.first else { return }
        anchor = TranscriptAnchor(pinned: false, key: first.key, top: geometry.topPadding + first.gapBefore)
        render()
    }

    func replaceWindow(_ messages: [HomeMessage], pending: [HomeMessage]) {
        pendingOlder.removeAll()
        pendingNewer.removeAll()
        loadingOlder = false
        loadingNewer = false
        let newest = source?.newestSeq ?? (messages.last?.seq ?? 0)
        let oldest = source?.oldestSeq ?? 1
        let change = history.replace(messages, pending: pending, newest: newest, oldest: oldest)
        rowLayout.apply(change, window: history, context: context())
        rowMotion.removeAll()
        rowFade.removeAll()
        committedTop.removeAll()
        pendingEvent = nil
    }
}

import AppKit

extension TranscriptView {
    /// A new source: drop the window, load its newest rows, follow its changes.
    func attachSource() {
        observation?.cancel()
        observation = nil
        generation += 1
        replaceWindow([], pending: [])
        lastSawNewest = 0
        typingIDs = []
        guard let source else {
            meID = ""
            render()
            return
        }
        meID = source.participants.first(where: \.isMe)?.id ?? ""
        typingIDs = source.typingParticipantIDs
        readThrough = source.readThroughSeq
        observation = source.observe { [weak self] change in self?.handle(change) }
        reload()
    }

    /// Loads the newest page of the source and pins to the bottom.
    func reload() {
        guard let source else { return }
        generation += 1
        let expected = generation
        let newest = source.newestSeq ?? 0
        anchor = TranscriptAnchor()
        Task { @MainActor [weak self] in
            let page = newest > 0 ? ((try? await source.page(before: newest + 1, limit: Self.pageSize)) ?? []) : []
            guard let self, self.generation == expected else { return }
            let measured = await self.measureOffMain(page)
            guard self.generation == expected else { return }
            self.replaceWindow(measured, pending: source.pendingMessages)
            self.render()
        }
    }

    /// Measures a page on a background thread before it joins the window.
    func measureOffMain(_ messages: [HomeMessage]) async -> [HomeMessage] {
        let measurer = measurer, geometry = geometry
        return await Task.detached(priority: .userInitiated) {
            measurer.measure(messages, geometry: geometry)
            return messages
        }.value
    }

    /// Loads the next page in the direction the viewport is heading.
    func checkPaging() {
        guard let source, let range = visibleMessageRange() else { return }
        let count = history.count
        if range.lowerBound < Self.prefetchMessages, history.hasOlder, !loadingOlder, pendingOlder.isEmpty {
            loadingOlder = true
            let before = history.firstSeq
            let limit = min(Self.pageSize, before - history.oldestAvailable)
            let expected = generation
            Task { @MainActor [weak self] in
                let page = (try? await source.page(before: before, limit: limit)) ?? []
                guard let self, self.generation == expected else { return }
                let measured = await self.measureOffMain(page)
                guard self.generation == expected else { return }
                self.loadingOlder = false
                guard self.history.firstSeq == before, !measured.isEmpty else { return }
                self.pendingOlder = measured
                self.pagingClient.activate()
            }
        }
        if !history.atNewest, range.upperBound > count - Self.prefetchMessages, !loadingNewer, pendingNewer.isEmpty {
            loadingNewer = true
            let from = history.lastSeq + 1
            let before = min(history.newestKnown + 1, from + Self.pageSize)
            let expected = generation
            Task { @MainActor [weak self] in
                let page = (try? await source.page(before: before, limit: before - from)) ?? []
                guard let self, self.generation == expected else { return }
                let measured = await self.measureOffMain(page)
                guard self.generation == expected else { return }
                self.loadingNewer = false
                guard self.history.lastSeq + 1 == from, !measured.isEmpty else { return }
                self.pendingNewer = measured
                self.pagingClient.activate()
            }
        }
    }

    /// One delivered chunk per frame, so a frame never pays for a whole page.
    func pagingFrame() -> Bool {
        applyPageChunk()
        render()
        return !pendingOlder.isEmpty || !pendingNewer.isEmpty
    }

    /// Joins the next chunk of a delivered page (the part adjacent to the window first).
    func applyPageChunk() {
        let change: WindowChange
        if !pendingOlder.isEmpty {
            let k = min(Self.chunkSize, pendingOlder.count)
            let chunk = Array(pendingOlder.suffix(k))
            pendingOlder.removeLast(k)
            change = history.prepend(chunk)
            if change == .none { pendingOlder.removeAll() }
        } else if !pendingNewer.isEmpty {
            let k = min(Self.chunkSize, pendingNewer.count)
            let chunk = Array(pendingNewer.prefix(k))
            pendingNewer.removeFirst(k)
            change = history.appendConfirmed(chunk)
            if change == .none { pendingNewer.removeAll() }
        } else {
            return
        }
        rowLayout.apply(change, window: history, context: context())
        evictFar()
    }

    /// Keeps the window within `TranscriptWindow.maxMessages`, dropping the side far from the viewport.
    func evictFar() {
        let count = history.confirmed.count
        guard count > TranscriptWindow.maxMessages, let range = visibleMessageRange() else { return }
        let extra = count - TranscriptWindow.maxMessages
        let change: WindowChange
        if range.lowerBound > count - range.upperBound, range.lowerBound - extra > Self.prefetchMessages {
            change = history.evict(top: extra, bottom: 0)
        } else if !anchor.pinned, count - range.upperBound - extra > Self.prefetchMessages {
            change = history.evict(top: 0, bottom: extra)
        } else {
            return
        }
        rowLayout.apply(change, window: history, context: context())
    }
}

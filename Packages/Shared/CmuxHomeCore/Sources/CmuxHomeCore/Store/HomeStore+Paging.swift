import Foundation

// HomeStore's transcript paging: open, close, older pages, and the one
// transcript read per conversation. HomeTranscriptPager owns the view counts,
// epochs and running reads; the store runs the reads against the mirror.
extension HomeStore {
    // MARK: Paging

    /// A view shows the conversation's transcript; each call pairs with one
    /// `close`. Loads the newest messages the first time it opens. Events
    /// committed while the page loads are buffered and kept.
    public func open(_ id: ConversationID) async {
        await beginOpen(id).value
    }

    /// `open` without waiting: the view counts as shown when this returns,
    /// so a `close` right after pairs with it. The task ends when the first
    /// page is in (at once when it already was).
    @discardableResult
    public func beginOpen(_ id: ConversationID) -> Task<Void, Never> {
        pager.open(id)
        if let running = pager.runningLoad(id) {
            // A read that started before a close reads again for this open.
            mirror.beginLoading(id)
            return running
        }
        guard mirror.windows[id] == nil else { return Task {} }
        // Switching back: the transcript it showed draws now, and the read below lays what the
        // owner holds over it (``HomeMirror/restoreKept(_:)``).
        if mirror.restoreKept(id) { bumpTranscript(id) } else { mirror.beginLoading(id) }
        return load(id)
    }

    /// A view of the conversation's transcript went away; pairs with one
    /// `open`. When the last one goes, the transcript is on screen nowhere:
    /// the store drops its window (the next `open` loads it again) and tells
    /// the source, which may end what it keeps for it (a cloud
    /// subscription, an archived conversation shown only while open).
    public func close(_ id: ConversationID) {
        guard pager.close(id) else { return }
        agentMessageReads.removeValue(forKey: id)?.cancel()
        agentMessageRefreshes.remove(id)
        agentMessages[id] = nil
        mirror.endTranscript(id)
        bumpTranscript(id)
        source.close(id)
    }

    public func loadOlder(_ id: ConversationID) async {
        guard let window = mirror.windows[id], !window.reachedStart, let first = window.firstSeq,
              pager.beginOlder(id) else { return }
        defer { pager.endOlder(id) }
        guard let older = try? await source.history(of: id, before: first, limit: Self.pageSize) else {
            // Retryable: the view shows it, and the next `loadOlder` asks again.
            if mirror.windows[id]?.firstSeq == first, mirror.setOlderFailed(true, in: id) { bumpTranscript(id) }
            return
        }
        // The window may have been replaced during the await; a page that no
        // longer joins it is dropped (the next scroll asks again).
        guard mirror.windows[id]?.firstSeq == first else { return }
        if mirror.prepend(older, to: id, reachedStart: older.count < Self.pageSize) {
            bumpTranscript(id)
            requestAgentMessages(id)
        }
    }

    /// Where the first page of the open transcript `id` stands (observable through
    /// `transcriptVersion`): ``TranscriptWindow/FirstPage/loading`` while its first read is out,
    /// ``TranscriptWindow/FirstPage/failed`` when that read failed (``retryTranscript(_:)`` reads
    /// again; a reconnect does too). A view draws an empty transcript as an empty conversation (a
    /// first-run panel) only when it is loaded.
    public func transcriptFirstPage(_ id: ConversationID) -> TranscriptWindow.FirstPage {
        _ = transcriptVersion[id]
        return mirror.windows[id]?.firstPage ?? .loaded
    }

    /// Whether the last older page of `id` failed (observable through `transcriptVersion`); the
    /// next ``loadOlder(_:)`` asks again and clears it when the page comes.
    public func olderMessagesFailed(in id: ConversationID) -> Bool {
        _ = transcriptVersion[id]
        return mirror.windows[id]?.olderFailed ?? false
    }

    /// Reads the open transcript `id` again after its first read failed (a view's Retry). The task
    /// ends when the read does; nothing happens when the transcript is shown nowhere. A first
    /// read that is still out (it hung past its deadline) is not asked again: the view shows
    /// loading again under a fresh deadline, and that read's page still lands.
    @discardableResult
    public func retryTranscript(_ id: ConversationID) -> Task<Void, Never> {
        guard pager.isShown(id), mirror.windows[id] != nil else { return Task {} }
        if let running = pager.runningLoad(id) {
            if mirror.retryFirstPage(id) { bumpTranscript(id) }
            armFirstPageDeadline(id)
            return running
        }
        return load(id)
    }

    /// Arms the deadline of `id`'s first read while its first page is loading: past
    /// ``firstPageDeadline`` the first page is failed (the view's error with Retry), never loading
    /// forever. A page that lands later still replaces the error.
    func armFirstPageDeadline(_ id: ConversationID) {
        firstPageDeadlines.removeValue(forKey: id)?.cancel()
        guard mirror.windows[id]?.firstPage == .loading else { return }
        let clock = self.clock
        // task-owner: one first-read deadline of transcript `id`; cancelled when the read ends, by a retry and by stop()
        firstPageDeadlines[id] = Task { [weak self] in
            do { try await clock.sleep(for: HomeStore.firstPageDeadline) } catch { return }
            guard let self, !self.stopped else { return }
            self.firstPageDeadlines[id] = nil
            if self.mirror.markFirstPageFailed(id) { self.bumpTranscript(id) }
        }
    }

    /// The conversation's transcript read, or the one already running.
    @discardableResult
    func load(_ id: ConversationID) -> Task<Void, Never> {
        if let running = pager.runningLoad(id) { return running }
        let task = Task {
            await self.readTranscript(id)
            self.pager.setLoad(nil, for: id)
        }
        pager.setLoad(task, for: id)
        return task
    }

    /// Reads the conversation's tail until it is caught up (at most three
    /// gaps per call), only while a view shows it. A failure leaves it
    /// stale, and a first page that failed says so (``transcriptFirstPage(_:)``);
    /// the next reconnect or ``retryTranscript(_:)`` reads it again.
    ///
    /// Shown nowhere, nothing is read: a read would set up what only a
    /// `close` ends (a cloud subscription). Without a window a stale mark
    /// only holds intents back, and the inbox carries the summary, so it
    /// is cleared. A page that comes back after its transcript closed is
    /// dropped (the close ended the window and told the source); one that
    /// comes back after a close and a new open is read again, so the source
    /// sets up again what the close ended. A read that returns after its
    /// transcript closed closes the source again.
    private func readTranscript(_ id: ConversationID) async {
        let stream = HomeStream.conversation(id)
        var gaps = 0
        while gaps < 3, !stopped {
            guard pager.isShown(id) else {
                mirror.endTranscript(id)
                settle()
                rebuildRows()
                return
            }
            let epoch = pager.epoch(id)
            // A read after a failed first one: the view shows loading again, not the error.
            if mirror.retryFirstPage(id) { bumpTranscript(id) }
            armFirstPageDeadline(id)
            let page = try? await source.snapshot(of: id, tail: Self.tailSize)
            firstPageDeadlines.removeValue(forKey: id)?.cancel()
            guard !stopped else { return }
            guard pager.isShown(id) else {
                // Closed while the read ran. The source reads off the main
                // actor, so the close may have reached it before the read
                // set anything up (a cloud subscription), which the read
                // then did: close it again.
                source.close(id)
                return
            }
            guard pager.epoch(id) == epoch else { continue }
            guard let page else {
                mirror.markStale(stream)
                // The first page did not come: an error with Retry, never an empty conversation.
                if mirror.markFirstPageFailed(id) { bumpTranscript(id) }
                return
            }
            let outcome = mirror.apply(page: page)
            confirm([page.conversation.id])
            bumpTranscript(id)
            settle()
            rebuildRows()
            // A view joins mid-run: the owner's live text so far (`run.live`).
            if outcome == .applied {
                requestLive(id)
                requestAgentMessages(id)
            }
            if outcome == .applied { return }
            gaps += 1
        }
    }
}

extension HomeStore {
    /// A message permalink as the conversation's owner resolves it (nil: no resolver, or a failure).
    public func resolveLink(_ id: ConversationID, message: MessageID) async -> HomeLinkTarget? {
        try? await source.resolveLink(conversation: id, message: message)
    }

    /// The seq of the oldest loaded message of `id` (nil: nothing loaded).
    public func oldestLoadedSeq(in id: ConversationID) -> Seq? { mirror.windows[id]?.firstSeq }
}

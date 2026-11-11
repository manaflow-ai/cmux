import AppKit
import CmuxHomeCore

/// The transcript's load state (ui-state-fixes M1): an empty transcript is an empty conversation
/// only once its first page was read. While the read is out it says "Loading messages…"; when it
/// failed, "Couldn't load messages." with Try Again (``HomeTranscriptLoadStateView``), and the
/// first-run panel stays hidden. A failed older page puts Try Again in the notice.
extension HomeNativeTranscriptView {
    /// Keeps ``firstPage`` and ``olderFailed`` on the store's state for this conversation, until `stop()`.
    func followTranscriptLoad() {
        guard !stopped else { return }
        let store = binding.store, id = binding.conversation
        let (page, older) = withObservationTracking {
            (store.transcriptFirstPage(id), store.olderMessagesFailed(in: id))
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.followTranscriptLoad() }
        }
        applyTranscriptLoad(page: page, older: older)
    }

    /// Shows the first page's state and a failed older page's notice.
    func applyTranscriptLoad(page: TranscriptWindow.FirstPage, older: Bool) {
        if page != firstPage {
            firstPage = page
            updateFirstRun()
        }
        if older != olderFailed {
            olderFailed = older
            if older {
                showNotice(HomeStrings.olderLoadFailed, action: HomeNoticeAction(title: HomeStrings.transcriptRetry) { [weak self] in
                    self?.retryOlder()
                })
            } else if notice == HomeStrings.olderLoadFailed {
                showNotice(nil)
            }
        }
    }

    /// Try Again on a failed first page: the store reads the transcript again (loading shows meanwhile).
    func retryTranscript() {
        binding.store.retryTranscript(binding.conversation)
    }

    /// Try Again on a failed older page.
    func retryOlder() {
        let store = binding.store, id = binding.conversation
        olderFailed = false
        showNotice(nil)
        olderRetry?.cancel()
        // task-owner: one older-page read, held in `olderRetry`; the next Try Again and stop() cancel
        // it. A second failure leaves the store's state as it was (no change to observe), so the
        // notice comes back from the read's own result.
        olderRetry = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await store.loadOlder(id)
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.olderRetry = nil
            self.applyTranscriptLoad(page: store.transcriptFirstPage(id), older: store.olderMessagesFailed(in: id))
        }
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// What the load state shows now: "loading", "failed" or nil (capture scenes, tests).
    public var debugTranscriptLoadState: String? {
        switch loadState.state {
        case .loading: "loading"
        case .failed: "failed"
        case .loaded, nil: nil
        }
    }
    #endif
}

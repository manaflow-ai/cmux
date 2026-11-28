extension FileDiffPageView {
    func expansionRowStatus(
        for snapshot: DiffExpanderSnapshot
    ) -> DiffExpansionRowStatus {
        if expansionContentTooLarge { return .tooLarge }
        if pendingExpansionGapID == snapshot.gap.id,
           let pendingExpansionDirection {
            return .loading(pendingExpansionDirection)
        }
        if failedExpansionGapID == snapshot.gap.id,
           let failedExpansionDirection {
            return .failed(failedExpansionDirection)
        }
        return .ready
    }

    @MainActor
    func expand(
        _ snapshot: DiffExpanderSnapshot,
        direction: DiffExpansionDirection
    ) {
        guard !expansionContentTooLarge else { return }
        cancelContinuationTask()
        continuationLoadState = .idle
        failedExpansionGapID = nil
        failedExpansionDirection = nil

        if let currentFileLines {
            scheduleCachedLinesRebuild(
                snapshot: snapshot,
                direction: direction,
                currentFileLines: currentFileLines
            )
            return
        }

        guard pendingExpansionGapID == nil else { return }
        expansionTask?.cancel()
        let generation = requestGeneration.begin()
        pendingExpansionGapID = snapshot.gap.id
        pendingExpansionDirection = direction
        expansionTask = Task { @MainActor in
            await loadCurrentLinesAndExpand(
                snapshot: snapshot,
                direction: direction,
                generation: generation
            )
        }
    }

    @MainActor
    private func scheduleCachedLinesRebuild(
        snapshot: DiffExpanderSnapshot,
        direction: DiffExpansionDirection,
        currentFileLines: [String]
    ) {
        guard let document = applyRevealIntent(
            snapshot: snapshot,
            direction: direction,
            currentFileLines: currentFileLines
        ) else { return }

        expansionTask?.cancel()
        let generation = requestGeneration.begin()
        let nextExpansionState = expansionState
        pendingExpansionGapID = snapshot.gap.id
        pendingExpansionDirection = direction
        expansionTask = Task { @MainActor in
            guard !Task.isCancelled,
                  requestGeneration.isCurrent(generation) else { return }
            await recomputePresentation(
                for: document,
                expansionState: nextExpansionState,
                currentFileLines: currentFileLines,
                generation: generation
            )
        }
    }

    @MainActor
    private func loadCurrentLinesAndExpand(
        snapshot: DiffExpanderSnapshot,
        direction: DiffExpansionDirection,
        generation: UInt64
    ) async {
        do {
            let currentFile = try await onLoadCurrentLines(file.path)
            guard !Task.isCancelled,
                  requestGeneration.isCurrent(generation),
                  case .loaded(let presentation) = loadState else { return }
            let revisionDecision = DiffExpansionRevisionPolicy().decision(
                diffContentFingerprint: presentation.document.contentFingerprint,
                fetchedContentFingerprints: currentFile.contentFingerprints
            )
            guard revisionDecision == .accept else {
                expansionTask = nil
                await load(forceRefresh: true)
                return
            }
            guard let document = applyRevealIntent(
                snapshot: snapshot,
                direction: direction,
                currentFileLines: currentFile.lines
            ) else {
                // The tapped gap resolved to nothing against the fetched file,
                // e.g. the trailing band on an added or EOF-touching diff whose
                // last hunk already covers every line. Publish the fetched
                // lines anyway so the projection learns the line count, the
                // dead band disappears, and later taps stop re-downloading.
                if case .loaded(let currentPresentation) = loadState {
                    await recomputePresentation(
                        for: currentPresentation.document,
                        expansionState: expansionState,
                        currentFileLines: currentFile.lines,
                        generation: generation
                    )
                } else {
                    clearPendingExpansion()
                    expansionTask = nil
                }
                return
            }
            let nextExpansionState = expansionState
            await recomputePresentation(
                for: document,
                expansionState: nextExpansionState,
                currentFileLines: currentFile.lines,
                generation: generation
            )
        } catch is CancellationError {
            guard requestGeneration.isCurrent(generation),
                  RecoverableCancellationErrorPolicy().shouldPublishFailure(
                      taskIsCancelled: Task.isCancelled
                  ) else { return }
            publishExpansionFailure(snapshot: snapshot, direction: direction)
        } catch DiffExpansionContentError.tooLarge {
            guard !Task.isCancelled,
                  requestGeneration.isCurrent(generation) else { return }
            clearPendingExpansion()
            expansionTask = nil
            expansionContentTooLarge = true
        } catch {
            guard !Task.isCancelled,
                  requestGeneration.isCurrent(generation) else { return }
            publishExpansionFailure(snapshot: snapshot, direction: direction)
        }
    }

    @MainActor
    private func applyRevealIntent(
        snapshot: DiffExpanderSnapshot,
        direction: DiffExpansionDirection,
        currentFileLines: [String]
    ) -> FileDiffDocument? {
        guard case .loaded(let presentation) = loadState else { return nil }
        let document = presentation.document
        guard let gap = DiffGap.gaps(
            for: document,
            currentFileLineCount: currentFileLines.count
        ).first(where: { $0.id == snapshot.gap.id }) else { return nil }
        expansionState.reveal(
            in: gap,
            direction: direction,
            preferredHiddenRange: snapshot.hiddenNewLineRange
        )
        self.currentFileLines = currentFileLines
        return document
    }

    @MainActor
    func resetExpansion() {
        expansionTask?.cancel()
        expansionTask = nil
        expansionState = DiffExpansionState()
        currentFileLines = nil
        clearPendingExpansion()
        failedExpansionGapID = nil
        failedExpansionDirection = nil
        expansionContentTooLarge = false
    }

    @MainActor
    func cancelExpansionTask() {
        expansionTask?.cancel()
        expansionTask = nil
        clearPendingExpansion()
    }

    @MainActor
    func cancelContinuationTask() {
        continuationTask?.cancel()
        continuationTask = nil
        if continuationLoadState == .loading {
            continuationLoadState = .idle
        }
    }

    @MainActor
    func cancelPageTasks() {
        cancelExpansionTask()
        cancelContinuationTask()
        requestGeneration.invalidate()
    }

    @MainActor
    private func recomputePresentation(
        for document: FileDiffDocument,
        expansionState nextExpansionState: DiffExpansionState,
        currentFileLines nextCurrentFileLines: [String],
        generation: UInt64
    ) async {
        guard let presentation =
            await FileDiffPresentation.prepareOffMainCancellable(
                document: document,
                expansionState: nextExpansionState,
                currentFileLines: nextCurrentFileLines,
                fileKind: file.kind
            ),
            !Task.isCancelled,
            requestGeneration.isCurrent(generation),
            case .loaded(let currentPresentation) = loadState,
            currentPresentation.document == document else { return }
        expansionState = nextExpansionState
        currentFileLines = nextCurrentFileLines
        clearPendingExpansion()
        failedExpansionGapID = nil
        failedExpansionDirection = nil
        expansionTask = nil
        loadState = .loaded(presentation)
    }

    @MainActor
    private func publishExpansionFailure(
        snapshot: DiffExpanderSnapshot,
        direction: DiffExpansionDirection
    ) {
        clearPendingExpansion()
        expansionTask = nil
        failedExpansionGapID = snapshot.gap.id
        failedExpansionDirection = direction
    }

    @MainActor
    private func clearPendingExpansion() {
        pendingExpansionGapID = nil
        pendingExpansionDirection = nil
    }
}

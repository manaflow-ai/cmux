import Foundation

extension ChromiumBrowserSession {
    /// Streams lifecycle and page metadata, beginning with the current value.
    ///
    /// - Returns: A stream that ends when its consumer cancels.
    public func snapshots() -> StateStream {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            stateContinuations[id] = continuation
            continuation.yield(snapshot())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStateContinuation(id) }
            }
        }
    }

    /// Streams compressed viewport frames from Chromium's `Page.startScreencast`.
    ///
    /// The stream survives child-process crashes so the same host view receives
    /// frames from a replacement renderer. It ends only when the pane stops.
    ///
    /// - Returns: A newest-frame-buffered stream of encoded images.
    public func frames() -> FrameStream {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            frameContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeFrameContinuation(id) }
            }
        }
    }

    /// Re-broadcasts one decoded screencast frame to the pane's frame streams.
    ///
    /// The connection-level stream dies with its connection; the session-level
    /// streams survive a renderer restart, so the host view never resubscribes.
    func forwardScreencastFrame(
        _ frame: Data,
        connection: ChromiumCDPConnection,
        generation: UInt64
    ) {
        guard isCurrentConnection(connection, generation: generation) else { return }
        for continuation in frameContinuations.values { continuation.yield(frame) }
    }

    /// Returns the session's current immutable metadata snapshot.
    ///
    /// - Returns: Current lifecycle and page metadata.
    public func snapshot() -> ChromiumSessionSnapshot {
        let externallyVisible: BrowserCDPEndpoint?
        if case .running(let endpoint?) = state,
           requestedRemoteDebuggingPort.isExternallyAttachable {
            externallyVisible = endpoint
        } else {
            externallyVisible = nil
        }
        return ChromiumSessionSnapshot(
            state: state,
            currentURL: currentURL,
            title: title,
            externallyVisibleEndpoint: externallyVisible,
            canGoBack: canGoBack,
            canGoForward: canGoForward,
            backHistoryURLs: backHistoryURLs,
            forwardHistoryURLs: forwardHistoryURLs,
            isLoading: isLoading,
            navigationRevision: navigationRevision
        )
    }

    private func removeStateContinuation(_ id: UUID) {
        stateContinuations.removeValue(forKey: id)
    }

    private func removeFrameContinuation(_ id: UUID) {
        frameContinuations.removeValue(forKey: id)
    }

    func publish() {
        let value = snapshot()
        for continuation in stateContinuations.values {
            continuation.yield(value)
        }
    }
}

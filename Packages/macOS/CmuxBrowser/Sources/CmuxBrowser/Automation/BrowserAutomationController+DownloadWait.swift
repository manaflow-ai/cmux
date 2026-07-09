public import Foundation

extension BrowserAutomationController {
    /// Pops the oldest queued download event for `surfaceId` from the worker lane,
    /// hopping to the main actor for the dictionary read.
    ///
    /// The returned `[String: Any]?` is not statically `Sendable`, so it crosses
    /// the synchronous main hop through a `nonisolated(unsafe)` box rather than the
    /// `Sendable`-constrained ``runMainSync(_:)``; the worker thread blocks on
    /// `DispatchQueue.main.sync` until the read completes, so the box is never
    /// accessed concurrently.
    nonisolated func popDownloadEventOnMain(surfaceId: UUID) -> [String: Any]? {
        nonisolated(unsafe) var result: [String: Any]?
        if Thread.isMainThread {
            MainActor.assumeIsolated { result = self.surfaceState.popDownloadEvent(surfaceId: surfaceId) }
            return result
        }
        DispatchQueue.main.sync {
            MainActor.assumeIsolated { result = self.surfaceState.popDownloadEvent(surfaceId: surfaceId) }
        }
        return result
    }
    /// Waits up to `timeout` for a captured download event for `surfaceId`,
    /// returning the event dict or `nil` on timeout.
    ///
    /// Byte-faithful relocation of the legacy `v2WaitForDownloadEvent`: registers
    /// a ``browserDownloadEventDidArriveName`` observer, immediately drains any
    /// already-queued event (popped on the main actor), and blocks on a
    /// `DispatchSemaphore` bounded by `timeout`. The `finishOnce` latch (guarded
    /// by an `NSLock`) ensures a late notification after the timeout is ignored,
    /// and the observer is removed before returning.
    public nonisolated func waitForDownloadEvent(
        surfaceId: UUID,
        timeout: TimeInterval
    ) -> [String: Any]? {
        let lock = NSLock()
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var finished = false
        nonisolated(unsafe) var event: [String: Any]?
        var observer: (any NSObjectProtocol)?

        let finishOnce: @Sendable ([String: Any]?) -> Void = { value in
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            event = value
            lock.unlock()
            semaphore.signal()
        }

        observer = NotificationCenter.default.addObserver(
            forName: Self.browserDownloadEventDidArriveName,
            object: nil,
            queue: nil
        ) { note in
            guard let candidateSurfaceId = note.userInfo?["surfaceId"] as? UUID,
                  candidateSurfaceId == surfaceId,
                  let event = note.userInfo?["event"] as? [String: Any] else {
                return
            }
            finishOnce(event)
        }

        if let queued = popDownloadEventOnMain(surfaceId: surfaceId) {
            finishOnce(queued)
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            finishOnce(nil)
        }
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        return event
    }
}

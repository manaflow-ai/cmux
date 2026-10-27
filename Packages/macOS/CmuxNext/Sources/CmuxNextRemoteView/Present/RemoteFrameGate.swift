import CmuxNextCompat

/// Passes decoded frames to a presenter until closed: once `close()` returns, no frame reaches the
/// presenter, even one whose decode was in flight (a hidden tab decodes and shows nothing). A
/// frame is presented inside the lock, so `close()` waits for a present in progress. One gate
/// per session of a pane. A reviewed lock site (plans/cmux-next/threading-model.md, "remote view
/// frame gate"): held across a mailbox post only, gate before mailbox.
package nonisolated final class RemoteFrameGate: Sendable {
    private let open = Mutex(true)

    package init() {}

    /// Presents `frame` while the gate is open; false when it is closed.
    @discardableResult
    package func deliver(_ frame: RemoteDecodedFrame, to presenter: any RemoteFramePresenter) -> Bool {
        open.withLock { open in
            if open { presenter.present(frame) }
            return open
        }
    }

    package func close() {
        open.withLock { $0 = false }
    }
}

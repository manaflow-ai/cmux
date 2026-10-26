import CmuxNextCompat

/// Passes decoded frames to a presenter until closed: once `close()` returns, no frame reaches the
/// presenter, even one whose decode was in flight (a hidden tab decodes and shows nothing). A
/// frame is presented inside the lock, so `close()` waits for a present in progress. Each gate
/// is one session of a pane: `deliver` says which frame is its first.
package nonisolated final class RemoteFrameGate: Sendable {
    /// What happened to one frame.
    package nonisolated enum Outcome: Sendable, Equatable {
        /// The gate is closed: nothing was presented.
        case dropped
        /// The first frame this gate presented.
        case first
        case presented
    }

    private struct State {
        var open = true
        var presented = false
    }

    private let state = Mutex(State())

    package init() {}

    /// Presents `frame` while the gate is open.
    @discardableResult
    package func deliver(_ frame: RemoteDecodedFrame, to presenter: any RemoteFramePresenter) -> Outcome {
        state.withLock { state in
            guard state.open else { return .dropped }
            presenter.present(frame)
            defer { state.presented = true }
            return state.presented ? .presented : .first
        }
    }

    package func close() {
        state.withLock { $0.open = false }
    }
}

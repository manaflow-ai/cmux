internal import os

/// Safety: the lock protects every state transition and the stored continuation.
/// The single waiter and idempotent start move that continuation out at most
/// once, and resume it only after releasing the lock. The coordinator must
/// store the prepared Task before `start()` releases it; actor suspension at
/// this boundary could break that order.
final class TerminalSurfaceRuntimeTeardownStartGate: @unchecked Sendable {
  private enum State {
    case pending
    case waiting(CheckedContinuation<Void, Never>)
    case started
  }

  private let state = OSAllocatedUnfairLock(initialState: State.pending)

  func wait() async {
    await withCheckedContinuation { continuation in
      let startImmediately = state.withLock { state in
        switch state {
        case .pending:
          state = .waiting(continuation)
          return false
        case .started:
          return true
        case .waiting:
          preconditionFailure(
            "teardown start gate waited more than once"
          )
        }
      }
      if startImmediately {
        continuation.resume()
      }
    }
  }

  func start() {
    let continuation = state.withLock { state in
      switch state {
      case .pending:
        state = .started
        return nil
      case .waiting(let continuation):
        state = .started
        return continuation
      case .started:
        return nil
      }
    }
    continuation?.resume()
  }
}

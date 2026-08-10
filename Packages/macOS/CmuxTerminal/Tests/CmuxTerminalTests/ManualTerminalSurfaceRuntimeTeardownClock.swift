import Foundation
import os

struct ManualTerminalSurfaceRuntimeTeardownInstant:
  InstantProtocol
{
  typealias Duration = Swift.Duration

  let offset: Duration

  func advanced(by duration: Duration) -> Self {
    Self(offset: offset + duration)
  }

  func duration(to other: Self) -> Duration {
    other.offset - offset
  }

  static func < (
    lhs: ManualTerminalSurfaceRuntimeTeardownInstant,
    rhs: ManualTerminalSurfaceRuntimeTeardownInstant
  ) -> Bool {
    lhs.offset < rhs.offset
  }
}

/// Manual clock whose positive registration stream is the test's watchdog
/// readiness signal. Advancing one registration resumes only that watchdog.
final class ManualTerminalSurfaceRuntimeTeardownClock:
  Clock,
  @unchecked Sendable
{
  typealias Duration = Swift.Duration
  typealias Instant = ManualTerminalSurfaceRuntimeTeardownInstant

  private struct Waiter {
    let deadline: Instant
    let continuation: CheckedContinuation<Void, any Error>
  }

  private struct State {
    var now = Instant(offset: .zero)
    var nextID = 0
    var waiters: [Int: Waiter] = [:]
    var cancelledIDs: Set<Int> = []
  }

  let registrations: AsyncStream<Int>
  private let registrationContinuation: AsyncStream<Int>.Continuation
  private let state = OSAllocatedUnfairLock(initialState: State())

  init() {
    (registrations, registrationContinuation) =
      AsyncStream.makeStream(of: Int.self)
  }

  var now: Instant {
    state.withLock(\.now)
  }

  var minimumResolution: Duration {
    .nanoseconds(1)
  }

  func sleep(
    until deadline: Instant,
    tolerance: Duration?
  ) async throws {
    try Task.checkCancellation()
    let id = state.withLock { state in
      let id = state.nextID
      state.nextID += 1
      return id
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let registered = state.withLock { state in
          if state.cancelledIDs.remove(id) != nil {
            return false
          }
          if deadline <= state.now {
            return false
          }
          state.waiters[id] = Waiter(
            deadline: deadline,
            continuation: continuation
          )
          return true
        }
        if registered {
          registrationContinuation.yield(id)
        } else if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          continuation.resume()
        }
      }
    } onCancel: {
      let waiter = state.withLock { state in
        guard let waiter = state.waiters.removeValue(forKey: id) else {
          state.cancelledIDs.insert(id)
          return nil
        }
        return waiter
      }
      waiter?.continuation.resume(throwing: CancellationError())
    }
  }

  func fire(_ id: Int) {
    let waiter = state.withLock { state in
      guard let waiter = state.waiters.removeValue(forKey: id) else {
        return nil
      }
      state.now = max(state.now, waiter.deadline)
      return waiter
    }
    waiter?.continuation.resume()
  }
}

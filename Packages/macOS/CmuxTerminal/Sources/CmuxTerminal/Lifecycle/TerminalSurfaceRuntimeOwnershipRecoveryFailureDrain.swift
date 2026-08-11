internal import os

/// Delivers stalled native-creation failures in bounded MainActor batches.
///
/// Admission keeps each queued callback counted against its bounded recovery
/// capacity until this drain delivers it. One transient task owns each batch;
/// idle state has no task cycle.
internal final class TerminalSurfaceRuntimeOwnershipRecoveryFailureDrain:
  @unchecked Sendable
{
  private static let maximumBatchCount = 32

  private struct State {
    var failures: [
      TerminalSurfaceRuntimeOwnershipRecoveryFailureDelivery
    ] = []
    var nextFailureIndex = 0
    var task: Task<Void, Never>?
  }

  private let maximumFailureCount: Int
  private let admission: TerminalSurfaceRuntimeOwnershipAdmission
  // Safety: this lock owns all mutable failure and task state. Failure
  // callbacks leave the lock before they run on the MainActor.
  private let state = OSAllocatedUnfairLock(uncheckedState: State())

  internal init(
    maximumFailureCount: Int,
    admission: TerminalSurfaceRuntimeOwnershipAdmission
  ) {
    precondition(maximumFailureCount > 0)
    self.maximumFailureCount = maximumFailureCount
    self.admission = admission
  }

  internal func enqueue(
    _ failures: [TerminalSurfaceRuntimeOwnershipRecoveryFailureDelivery]
  ) {
    guard !failures.isEmpty else { return }
    var startGate: TerminalSurfaceRuntimeTeardownStartGate?
    state.withLockUnchecked { state in
      let pendingCount = state.failures.count - state.nextFailureIndex
      precondition(
        pendingCount + failures.count <= maximumFailureCount,
        "stalled recovery failure drain must remain bounded"
      )
      if pendingCount == 0 {
        state.failures.removeAll(keepingCapacity: true)
        state.nextFailureIndex = 0
      }
      state.failures.append(contentsOf: failures)
      prepareTaskIfNeeded(state: &state, startGate: &startGate)
    }
    startGate?.start()
  }

  deinit {
    state.withLockUnchecked { state in
      state.task?.cancel()
      state.task = nil
    }
  }

  private func prepareTaskIfNeeded(
    state: inout State,
    startGate: inout TerminalSurfaceRuntimeTeardownStartGate?
  ) {
    guard state.task == nil else { return }
    let gate = TerminalSurfaceRuntimeTeardownStartGate()
    state.task = Task { @MainActor [self] in
      await gate.wait()
      runScheduledBatch()
    }
    startGate = gate
  }

  @MainActor
  private func runScheduledBatch() {
    let batch = state.withLockUnchecked { state in
      let endIndex = min(
        state.nextFailureIndex + Self.maximumBatchCount,
        state.failures.count
      )
      let batch = Array(state.failures[state.nextFailureIndex..<endIndex])
      state.nextFailureIndex = endIndex
      return batch
    }
    for failure in batch {
      failure()
    }
    admission.completeStalledCloseRecoveryFailures(batch)

    var startGate: TerminalSurfaceRuntimeTeardownStartGate?
    state.withLockUnchecked { state in
      state.task = nil
      if state.nextFailureIndex == state.failures.count {
        state.failures.removeAll(keepingCapacity: true)
        state.nextFailureIndex = 0
      } else {
        prepareTaskIfNeeded(state: &state, startGate: &startGate)
      }
    }
    startGate?.start()
  }
}

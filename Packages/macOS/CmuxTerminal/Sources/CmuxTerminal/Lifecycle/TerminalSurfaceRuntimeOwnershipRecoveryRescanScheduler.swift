internal import CmuxTerminalCore
internal import os

/// Coalesces MainActor scans for surface-owned overflow recovery intents.
///
/// The registry stores weak surface entries. This scheduler stores no surface
/// or recovery closure; the strong array exists only for one synchronous scan.
internal final class TerminalSurfaceRuntimeOwnershipRecoveryRescanScheduler:
  @unchecked Sendable
{
  private struct State {
    var nextSequence: UInt64 = 0
    var registry: (any TerminalSurfaceRegistering)?
    var rescanRequested = false
    var rescanTask: Task<Void, Never>?
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  internal func registerOverflow(
    registry: any TerminalSurfaceRegistering
  ) -> UInt64 {
    var startGate: TerminalSurfaceRuntimeTeardownStartGate?
    let sequence = state.withLock { state in
      precondition(state.nextSequence < UInt64.max)
      state.nextSequence += 1
      if let registeredRegistry = state.registry {
        precondition(registeredRegistry === registry)
      } else {
        state.registry = registry
      }
      state.rescanRequested = true
      prepareRescanTaskIfNeeded(state: &state, startGate: &startGate)
      return state.nextSequence
    }
    startGate?.start()
    return sequence
  }

  internal func requestRescan() {
    var startGate: TerminalSurfaceRuntimeTeardownStartGate?
    state.withLock { state in
      guard state.registry != nil else { return }
      state.rescanRequested = true
      prepareRescanTaskIfNeeded(state: &state, startGate: &startGate)
    }
    startGate?.start()
  }

  deinit {
    state.withLock { state in
      state.rescanTask?.cancel()
      state.rescanTask = nil
    }
  }

  private func prepareRescanTaskIfNeeded(
    state: inout State,
    startGate: inout TerminalSurfaceRuntimeTeardownStartGate?
  ) {
    guard state.rescanTask == nil else { return }
    let gate = TerminalSurfaceRuntimeTeardownStartGate()
    state.rescanTask = Task { @MainActor [weak self] in
      await gate.wait()
      self?.drainRequestedRescans()
    }
    startGate = gate
  }

  @MainActor
  private func drainRequestedRescans() {
    while true {
      let registry = state.withLock { state in
        state.rescanRequested = false
        return state.registry
      }
      if let registry {
        rescan(registry: registry)
      }
      let shouldContinue = state.withLock { state in
        guard state.rescanRequested else {
          state.rescanTask = nil
          return false
        }
        return true
      }
      guard shouldContinue else { return }
    }
  }

  @MainActor
  private func rescan(registry: any TerminalSurfaceRegistering) {
    let surfaces = registry.allSurfaces()
      .compactMap { $0 as? TerminalSurface }
      .compactMap { surface in
        surface.runtimeSurfaceAdmissionOverflowSequence.map {
          (sequence: $0, surface: surface)
        }
      }
      .sorted { lhs, rhs in lhs.sequence < rhs.sequence }

    for entry in surfaces {
      guard
        let capacityReservation =
          entry.surface.runtimeTeardown
          .claimRuntimeSurfaceOwnershipRecoveryCapacity()
      else {
        return
      }
      entry.surface.retryRuntimeSurfaceCreationAfterAdmissionOverflow(
        capacityReservation: capacityReservation
      )
    }
  }
}

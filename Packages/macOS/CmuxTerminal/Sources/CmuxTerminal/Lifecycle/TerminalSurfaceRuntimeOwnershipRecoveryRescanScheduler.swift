internal import os

/// Coalesces bounded MainActor batches for surface-owned overflow recovery.
///
/// The FIFO stores one weak surface per public surface id. It does not retain
/// native-creation closures or surfaces, and each task processes a fixed batch
/// before yielding the main actor.
internal final class TerminalSurfaceRuntimeOwnershipRecoveryRescanScheduler:
  @unchecked Sendable
{
  private static let maximumBatchCount = 32

  private final class OverflowEntry {
    let surfaceID: UUID
    let sequence: UInt64
    weak var surface: TerminalSurface?
    var previousID: UUID?
    var nextID: UUID?

    init(
      surfaceID: UUID,
      sequence: UInt64,
      surface: TerminalSurface,
      previousID: UUID?
    ) {
      self.surfaceID = surfaceID
      self.sequence = sequence
      self.surface = surface
      self.previousID = previousID
    }
  }

  private struct State {
    var nextSequence: UInt64 = 0
    var entriesByID: [UUID: OverflowEntry] = [:]
    var headID: UUID?
    var tailID: UUID?
    var rescanRequested = false
    var rescanTask: Task<Void, Never>?
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  internal func registerOverflow(
    surfaceID: UUID,
    surface: TerminalSurface
  ) -> UInt64 {
    var startGate: TerminalSurfaceRuntimeTeardownStartGate?
    let sequence = state.withLock { state in
      if let entry = state.entriesByID[surfaceID] {
        entry.surface = surface
        state.rescanRequested = true
        prepareRescanTaskIfNeeded(state: &state, startGate: &startGate)
        return entry.sequence
      }

      precondition(state.nextSequence < UInt64.max)
      state.nextSequence += 1
      let previousID = state.tailID
      let entry = OverflowEntry(
        surfaceID: surfaceID,
        sequence: state.nextSequence,
        surface: surface,
        previousID: previousID
      )
      state.entriesByID[surfaceID] = entry
      if let previousID {
        state.entriesByID[previousID]?.nextID = surfaceID
      } else {
        state.headID = surfaceID
      }
      state.tailID = surfaceID
      state.rescanRequested = true
      prepareRescanTaskIfNeeded(state: &state, startGate: &startGate)
      return entry.sequence
    }
    startGate?.start()
    return sequence
  }

  internal func cancelOverflow(surfaceID: UUID) {
    let removed = state.withLock { state in
      removeOverflow(surfaceID: surfaceID, from: &state) != nil
    }
    if removed {
      requestRescan()
    }
  }

  internal func requestRescan() {
    var startGate: TerminalSurfaceRuntimeTeardownStartGate?
    state.withLock { state in
      guard state.headID != nil else { return }
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
      self?.runScheduledBatch()
    }
    startGate = gate
  }

  @MainActor
  private func runScheduledBatch() {
    let shouldRun = state.withLock { state in
      state.rescanRequested = false
      return state.headID != nil
    }
    var processedCount = 0
    if shouldRun {
      while processedCount < Self.maximumBatchCount {
        guard
          let entry = state.withLock({ state in
            state.headID.flatMap { state.entriesByID[$0] }
          })
        else {
          break
        }
        guard let surface = entry.surface else {
          state.withLock { state in
            _ = removeOverflow(
              surfaceID: entry.surfaceID,
              from: &state
            )
          }
          processedCount += 1
          continue
        }
        guard
          let capacityReservation =
            surface.runtimeTeardown
            .claimRuntimeSurfaceOwnershipRecoveryCapacity()
        else {
          break
        }
        surface.retryRuntimeSurfaceCreationAfterAdmissionOverflow(
          capacityReservation: capacityReservation
        )
        processedCount += 1

        let madeProgress = state.withLock { state in
          state.entriesByID[entry.surfaceID] == nil
        }
        guard madeProgress else { break }
      }
    }

    let followUp = state.withLock { state -> (OverflowEntry, Bool)? in
      state.rescanTask = nil
      let externallyRequested = state.rescanRequested
      state.rescanRequested = false
      guard let headID = state.headID,
        let entry = state.entriesByID[headID]
      else {
        return nil
      }
      return (entry, externallyRequested)
    }
    guard let (entry, externallyRequested) = followUp else { return }
    let batchWasExhausted = processedCount == Self.maximumBatchCount
    let capacityRemains: Bool
    if let surface = entry.surface {
      capacityRemains =
        surface.runtimeTeardown
        .runtimeSurfaceOwnershipRecoveryCapacityIsOpen()
    } else {
      capacityRemains = true
    }
    if capacityRemains && (batchWasExhausted || externallyRequested) {
      requestRescan()
    }
  }

  @discardableResult
  private func removeOverflow(
    surfaceID: UUID,
    from state: inout State
  ) -> OverflowEntry? {
    guard let entry = state.entriesByID.removeValue(forKey: surfaceID) else {
      return nil
    }
    if let previousID = entry.previousID {
      state.entriesByID[previousID]?.nextID = entry.nextID
    } else {
      state.headID = entry.nextID
    }
    if let nextID = entry.nextID {
      state.entriesByID[nextID]?.previousID = entry.previousID
    } else {
      state.tailID = entry.previousID
    }
    if state.entriesByID.isEmpty {
      state.headID = nil
      state.tailID = nil
      state.rescanRequested = false
    }
    return entry
  }
}

internal import Foundation
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

  private let maximumEntryCount: Int

  private final class OverflowEntry {
    let surfaceID: UUID
    let sequence: UInt64
    weak var surface: TerminalSurface?
    var failureReported = false
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
    // Every indexed entry is one linked FIFO node. Synchronous cancellation
    // removes both views under this lock, so no weak tombstone survives.
    var entriesByID: [UUID: OverflowEntry] = [:]
    var headID: UUID?
    var tailID: UUID?
    var failureThroughSequence: UInt64?
    var failureCursorID: UUID?
    var rescanRequested = false
    var rescanTask: Task<Void, Never>?
  }

  // Safety: this lock owns all mutable links and task state. The weak,
  // non-Sendable surface references are dereferenced only by the MainActor
  // batch in `runScheduledBatch()`.
  private let state = OSAllocatedUnfairLock(uncheckedState: State())

  internal init(maximumEntryCount: Int) {
    precondition(maximumEntryCount > 0)
    self.maximumEntryCount = maximumEntryCount
  }

  #if DEBUG
    internal var debugSnapshot:
      (
        entryCount: Int,
        linkedNodeCount: Int,
        headID: UUID?,
        tailID: UUID?
      )
    {
      state.withLockUnchecked { state in
        var linkedIDs = Set<UUID>()
        var currentID = state.headID
        while let nodeID = currentID, linkedIDs.insert(nodeID).inserted {
          currentID = state.entriesByID[nodeID]?.nextID
        }
        return (
          entryCount: state.entriesByID.count,
          linkedNodeCount: linkedIDs.count,
          headID: state.headID,
          tailID: state.tailID
        )
      }
    }
  #endif

  internal func registerOverflow(
    surfaceID: UUID,
    surface: TerminalSurface
  ) -> TerminalSurfaceRuntimeOwnershipRecoveryOverflowRegistration {
    var startGate: TerminalSurfaceRuntimeTeardownStartGate?
    let registration: TerminalSurfaceRuntimeOwnershipRecoveryOverflowRegistration =
      state.withLockUnchecked { state in
        if let entry = state.entriesByID[surfaceID] {
          entry.surface = surface
          entry.failureReported = false
          state.rescanRequested = true
          prepareRescanTaskIfNeeded(state: &state, startGate: &startGate)
          return .updated(sequence: entry.sequence)
        }

        guard state.entriesByID.count < maximumEntryCount else {
          return .rejected
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
        return .registered(sequence: entry.sequence)
      }
    startGate?.start()
    return registration
  }

  internal func cancelOverflow(surfaceID: UUID) {
    let removed = state.withLockUnchecked { state in
      removeOverflow(surfaceID: surfaceID, from: &state) != nil
    }
    if removed {
      requestRescan()
    }
  }

  internal func requestRescan() {
    var startGate: TerminalSurfaceRuntimeTeardownStartGate?
    state.withLockUnchecked { state in
      guard state.headID != nil else { return }
      state.rescanRequested = true
      prepareRescanTaskIfNeeded(state: &state, startGate: &startGate)
    }
    startGate?.start()
  }

  internal func failPendingOverflowCreations() {
    var startGate: TerminalSurfaceRuntimeTeardownStartGate?
    state.withLockUnchecked { state in
      guard let tailID = state.tailID,
        let tail = state.entriesByID[tailID]
      else { return }
      state.failureThroughSequence = max(
        state.failureThroughSequence ?? 0,
        tail.sequence
      )
      if state.failureCursorID == nil {
        state.failureCursorID = state.headID
      }
      state.rescanRequested = true
      prepareRescanTaskIfNeeded(state: &state, startGate: &startGate)
    }
    startGate?.start()
  }

  deinit {
    state.withLockUnchecked { state in
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
    let shouldRun = state.withLockUnchecked { state in
      state.rescanRequested = false
      return state.headID != nil
    }
    var processedCount = 0
    if shouldRun {
      while processedCount < Self.maximumBatchCount {
        if let failedEntry = state.withLockUnchecked({ state in
          takeNextFailureEntry(from: &state)
        }) {
          failedEntry.surface?
            .failRuntimeSurfaceCreationForTeardownCapacity(
              preservingRecoveryOwner: true
            )
          processedCount += 1
          continue
        }
        guard
          let entry = state.withLockUnchecked({ state in
            state.headID.flatMap { state.entriesByID[$0] }
          })
        else {
          break
        }
        guard let surface = entry.surface else {
          state.withLockUnchecked { state in
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

        let madeProgress = state.withLockUnchecked { state in
          state.entriesByID[entry.surfaceID] == nil
        }
        guard madeProgress else { break }
      }
    }

    let followUp = state.withLockUnchecked {
      state -> (OverflowEntry, Bool, Bool)? in
      state.rescanTask = nil
      let externallyRequested = state.rescanRequested
      state.rescanRequested = false
      guard let headID = state.headID,
        let entry = state.entriesByID[headID]
      else {
        return nil
      }
      return (
        entry,
        externallyRequested,
        state.failureThroughSequence != nil
      )
    }
    guard let (entry, externallyRequested, failurePending) = followUp else {
      return
    }
    let batchWasExhausted = processedCount == Self.maximumBatchCount
    let capacityRemains: Bool
    if failurePending {
      capacityRemains = true
    } else if let surface = entry.surface {
      capacityRemains =
        surface.runtimeTeardown
        .runtimeSurfaceOwnershipRecoveryCapacityIsOpen()
    } else {
      capacityRemains = true
    }
    if capacityRemains
      && (batchWasExhausted || externallyRequested || failurePending)
    {
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
    if state.failureCursorID == surfaceID {
      state.failureCursorID = entry.nextID
    }
    if state.entriesByID.isEmpty {
      state.headID = nil
      state.tailID = nil
      state.failureThroughSequence = nil
      state.failureCursorID = nil
      state.rescanRequested = false
    }
    return entry
  }

  private func takeNextFailureEntry(
    from state: inout State
  ) -> OverflowEntry? {
    guard let cutoff = state.failureThroughSequence else { return nil }
    while let currentID = state.failureCursorID,
      let entry = state.entriesByID[currentID]
    {
      guard entry.sequence <= cutoff else { break }
      state.failureCursorID = entry.nextID
      guard !entry.failureReported else { continue }
      entry.failureReported = true
      return entry
    }
    state.failureThroughSequence = nil
    state.failureCursorID = nil
    return nil
  }
}

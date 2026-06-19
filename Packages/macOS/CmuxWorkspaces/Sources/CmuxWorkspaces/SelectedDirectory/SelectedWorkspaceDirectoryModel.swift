public import Foundation
import Observation

/// Per-window model that observes the selected workspace's directory and
/// remote-connection state and exposes a monotonically increasing
/// ``directoryChangeGeneration`` that ticks once per distinct change.
///
/// This is the modernized lift of the private
/// `SelectedWorkspaceDirectoryObserver` (`ObservableObject` + `@Published`
/// `directoryChangeGeneration` + a Combine `combineLatest`/`switchToLatest`
/// pipeline with an `AnyCancellable`) that lived in `ContentView.swift`.
/// `ContentView` drives `syncFileExplorerDirectory()` off
/// `.onChange(of: directoryChangeGeneration)`; that consumer glue is
/// irreducibly app-target (it mutates `@State` and view-local stores) and
/// stays in the view, now observing this model instead of the observer.
///
/// **Isolation design.** `@MainActor` because the only writer is the
/// stream-consuming task started on the main actor and the only reader is
/// SwiftUI's `.onChange` on the main actor — state lives where its callers
/// live. `@Observable` (not `ObservableObject`) so the view tracks
/// `directoryChangeGeneration` through Observation; the migration direction is
/// Combine → `@Observable`.
///
/// **Single writer / dedup parity.** The model is the sole writer of
/// `directoryChangeGeneration`. It deduplicates snapshots itself — the legacy
/// pipeline's `removeDuplicates()` — so the generation advances exactly once
/// per distinct ``SelectedWorkspaceDirectorySnapshot``, never on an equal
/// snapshot. The first snapshot the stream delivers always advances the
/// generation (the legacy pipeline had no prior value to compare against, so
/// its first `.sink` emission bumped `0 → 1`); subsequent equal snapshots are
/// dropped. ``SelectedWorkspaceReading`` conformers forward every upstream
/// emission without deduplicating.
@MainActor
@Observable
public final class SelectedWorkspaceDirectoryModel {
    /// Ticks once per distinct selected-workspace directory/remote-state
    /// change. SwiftUI observes this to re-run the file-explorer sync. Starts
    /// at `0`; the first observed snapshot advances it to `1`, matching the
    /// legacy `@Published directoryChangeGeneration` contract.
    public private(set) var directoryChangeGeneration: UInt64 = 0

    /// The most recent snapshot delivered to the generation counter, used to
    /// deduplicate. `nil` until the first snapshot arrives so the first
    /// emission always bumps (legacy first-`.sink` behavior).
    @ObservationIgnored
    private var lastDeliveredSnapshot: SelectedWorkspaceDirectorySnapshot?

    /// The running stream-consumption task. Cancelled and replaced on each
    /// ``wire(reading:)`` so re-wiring to a new reader is idempotent, mirroring
    /// the legacy `cancellable == nil` guard.
    @ObservationIgnored
    private var consumeTask: Task<Void, Never>?

    /// The reader currently wired, used to short-circuit a redundant re-wire to
    /// the same source (legacy `self.tabManager !== tabManager` guard).
    @ObservationIgnored
    private var wiredReading: (any SelectedWorkspaceReading)?

    /// Creates a detached model; call ``wire(reading:)`` before use.
    public init() {}

    /// Subscribes to the reader's snapshot stream and begins advancing
    /// ``directoryChangeGeneration`` on each distinct snapshot.
    ///
    /// Idempotent: wiring the same reader instance again is a no-op (the legacy
    /// `self.tabManager !== tabManager || cancellable == nil` guard). Wiring a
    /// different reader cancels the previous subscription and starts a fresh
    /// one, resetting the dedup baseline so the new source's first snapshot
    /// bumps the generation.
    ///
    /// Identity is by object reference, so this takes `any SelectedWorkspaceReading & AnyObject`.
    public func wire(reading: any SelectedWorkspaceReading & AnyObject) {
        if let wiredReading, wiredReading as AnyObject === reading as AnyObject, consumeTask != nil {
            return
        }
        wiredReading = reading
        consumeTask?.cancel()
        lastDeliveredSnapshot = nil
        let snapshots = reading.directorySnapshots
        consumeTask = Task { [weak self] in
            for await snapshot in snapshots {
                guard let self else { return }
                self.deliver(snapshot)
            }
        }
    }

    /// Stops consuming the snapshot stream. The generation is left at its
    /// current value.
    public func stop() {
        consumeTask?.cancel()
        consumeTask = nil
        wiredReading = nil
        lastDeliveredSnapshot = nil
    }

    /// Applies one snapshot, advancing the generation only when it differs from
    /// the last delivered snapshot (legacy `removeDuplicates()` + `&+= 1`).
    private func deliver(_ snapshot: SelectedWorkspaceDirectorySnapshot) {
        if let lastDeliveredSnapshot, lastDeliveredSnapshot == snapshot {
            return
        }
        lastDeliveredSnapshot = snapshot
        directoryChangeGeneration &+= 1
    }

    deinit {
        consumeTask?.cancel()
    }
}

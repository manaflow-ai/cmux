import Foundation
import Observation
import CmuxNextCompat
import CmuxNextDesignTokens
import CmuxNextWakeups

/// One composite token (`Metrics.tabStripHeight`, `PaneChromeMetrics.current`), computed once and kept
/// until an input changes, so a live window resize that lays out every strip and row many times a
/// frame reads a stored value instead of re-walking dozens of tunables and settings. A window
/// resize's main-thread sample (2026-11-22, Debug) had these composites at about a fifth of the busy
/// samples: each tunable read locks the store twice and inserts a String-keyed Observation key path
/// into AppKit's per-layout access list, and one composite read makes dozens of them.
///
/// It stays live and tracked:
/// - A miss computes inside `withObservationTracking`; the first change to anything the value read
///   (a Debug Settings override, `DesignSettings`, the density) drops it. The miss runs inside the
///   caller's own tracking too, so that caller sees every input.
/// - Every read, hit or miss, registers one Observation access on the memo, which a drop mutates, so
///   a layout or view that read the composite re-runs when it changes.
/// - The change is announced in its `willSet`, before the new value is stored: from a drop until the
///   main queue's next turn the value is computed fresh and not kept (``settling``), so a read in that
///   window (an observer's own `didSet`) never stores the old value.
/// - A scoped density (`DensityTokens.$scoped`, previews and tests) and the store's activation (not
///   observable: it flips once at launch) bypass or re-key the memo.
@MainActor
final class TokenMemo<Value> {
    private let tracking = SingleArmedTracking()
    private var stored: Value?
    private var storedEpoch = -1
    private var storedActive = false
    /// Bumped by every drop (any thread: `withObservationTracking` calls back on the mutating one).
    nonisolated private let epoch = Atomic<Int>(0)
    /// Drops whose change may not have landed yet: the value is not kept while this is above 0.
    nonisolated private let settling = Atomic<Int>(0)
    nonisolated private let signal = TokenMemoSignal()

    init() {}
    nonisolated deinit {}

    /// The kept value, else `compute()` (kept when nothing changed while it ran).
    func value(_ compute: () -> Value) -> Value {
        signal.access()
        guard DensityTokens.scoped == nil else { return compute() }
        let active = TunableStore.shared.isActive
        let now = epoch.load(ordering: .acquiring)
        // A change is landing: compute in the caller's own tracking, keep nothing.
        guard settling.load(ordering: .acquiring) == 0 else { return compute() }
        if let stored, now == storedEpoch, active == storedActive { return stored }
        // Keyed on the store's activation: a registration armed while it was inert holds no tunable (`override` returns
        // before it registers), so activation arms a fresh one that does.
        let fresh = tracking.track(shape: active ? [ObjectIdentifier(TunableStore.shared)] : [], compute,
                                   onChange: { [weak self] in self?.drop() })
        if epoch.load(ordering: .acquiring) == now, settling.load(ordering: .acquiring) == 0 {
            stored = fresh
            storedEpoch = now
            storedActive = active
        }
        return fresh
    }

    nonisolated private func drop() {
        _ = settling.wrappingAdd(1, ordering: .acquiringAndReleasing)
        _ = epoch.wrappingAdd(1, ordering: .acquiringAndReleasing)
        signal.changed()
        // The change that dropped the value lands after its `willSet` returns; on the main queue's next
        // turn it has (writes are main-actor; a launch-time `settledOverride` merge is the one exception).
        MainDelivery().later { [weak self] in _ = self?.settling.wrappingSubtract(1, ordering: .acquiringAndReleasing) }
    }
}

/// The memo's Observation identity: one concrete, argument-free key path (made once by the runtime, cheap to
/// hash), unlike a generic class's key path, which is instantiated per read.
nonisolated private final class TokenMemoSignal: Observable, Sendable {
    private let registrar = ObservationRegistrar()
    private var generation: Int { 0 }

    func access() { registrar.access(self, keyPath: \.generation) }
    func changed() { registrar.withMutation(of: self, keyPath: \.generation) {} }
}

/// The composites a layout reads many times a frame (`Metrics.memo`), held by ``DesignSettings/shared``.
final class TokenMemos {
    let tabStripHeight = TokenMemo<CGFloat>(), tabHeight = TokenMemo<CGFloat>(), chromeRowHeight = TokenMemo<CGFloat>()
    let paneChrome = TokenMemo<PaneChromeMetrics>(), cornerFlush = TokenMemo<CornerFlush>(), sidebarRow = TokenMemo<SidebarRowTokens>()
}

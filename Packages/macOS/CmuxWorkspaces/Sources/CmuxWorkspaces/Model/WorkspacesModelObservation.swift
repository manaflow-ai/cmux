public import Foundation
internal import Observation

/// A cancellable handle for a re-arming ``WorkspacesModel`` observation. Holding
/// it keeps the watch armed; dropping it (or calling ``cancel()``) stops the
/// re-arm so no further change handlers fire.
///
/// The handle is the lifetime owner the retired `CurrentValueSubject` bridges
/// used an `AnyCancellable` for: a subscriber stores it for as long as it wants
/// the callback, and releasing it tears the watch down. Cancellation is
/// idempotent.
@MainActor
public final class WorkspacesObservation {
    /// Registers one `withObservationTracking` pass; set by the model so the
    /// handle can re-arm itself from inside its own change handler (the macro's
    /// `onChange` fires once per registration).
    fileprivate var armOnce: (() -> Void)?
    private var isCancelled = false

    fileprivate init() {}

    /// Whether the watch has been cancelled (handler must not fire again).
    fileprivate var cancelled: Bool { isCancelled }

    /// Re-arms the underlying watch. No-op once cancelled.
    fileprivate func reArm() {
        guard !isCancelled else { return }
        armOnce?()
    }

    /// Stops the watch. No change handler fires after this returns. Idempotent.
    public func cancel() {
        isCancelled = true
        armOnce = nil
    }
}

extension WorkspacesModel {
    /// Observes ``tabs`` and invokes `onChange` after every mutation of the
    /// array, including assignments of an equal value.
    ///
    /// This is the `@Observable` replacement for the retired
    /// `TabManager.tabsPublisher` `CurrentValueSubject` bridge. Two deliberate
    /// timing differences from that bridge, both behavior-affecting and verified
    /// per consumer:
    ///
    /// - **Delivered after the change commits, not during `willSet`.** The bridge
    ///   sent the new value from the `tabs` `willSet`, so a subscriber saw the new
    ///   list while `tabs` storage still held the old one. This delivers `onChange`
    ///   on a `MainActor` hop after the mutation, so `tabs` already reads the new
    ///   value inside `onChange` (the same hop the surviving consumers had from
    ///   `.receive(on: DispatchQueue.main)` / `.throttle(scheduler: RunLoop.main)`).
    /// - **No replay on subscribe.** `CurrentValueSubject` delivered the current
    ///   value immediately to a new `.sink`; this fires only on the *next* change.
    ///   A subscriber that relied on the initial replay performs its own initial
    ///   read once after calling this.
    ///
    /// Equal-value parity is preserved: the `@Observable` macro records a
    /// mutation on every set, so `onChange` fires on an equal re-assignment just
    /// as the bridge's `.send` did.
    ///
    /// The returned ``WorkspacesObservation`` owns the watch's lifetime; store it
    /// for as long as the callback is wanted and drop or ``WorkspacesObservation/cancel()``
    /// it to stop.
    public func observeTabs(_ onChange: @escaping @MainActor @Sendable () -> Void) -> WorkspacesObservation {
        observe({ _ = self.tabs }, onChange)
    }

    /// Observes ``selectedTabId`` and invokes `onChange` after every assignment,
    /// including equal-value assignments. Same timing/replay contract as
    /// ``observeTabs(_:)``; replaces `TabManager.selectedTabIdPublisher`.
    public func observeSelectedTabId(_ onChange: @escaping @MainActor @Sendable () -> Void) -> WorkspacesObservation {
        observe({ _ = self.selectedTabId }, onChange)
    }

    /// Observes ``workspaceGroups`` and invokes `onChange` after every mutation,
    /// including equal-value assignments. Same timing/replay contract as
    /// ``observeTabs(_:)``; replaces `TabManager.workspaceGroupsPublisher`.
    public func observeWorkspaceGroups(_ onChange: @escaping @MainActor @Sendable () -> Void) -> WorkspacesObservation {
        observe({ _ = self.workspaceGroups }, onChange)
    }

    /// Builds a re-arming `withObservationTracking` watch. `access` reads exactly
    /// the property to track; `onChange` runs after the property mutates, then
    /// the handle re-arms so subsequent changes are still delivered.
    private func observe(
        _ access: @escaping @MainActor () -> Void,
        _ onChange: @escaping @MainActor @Sendable () -> Void
    ) -> WorkspacesObservation {
        let handle = WorkspacesObservation()
        handle.armOnce = { [weak handle] in
            withObservationTracking {
                access()
            } onChange: {
                // Observation delivers `onChange` at `willSet` time on the
                // mutating context (the MainActor; the model's single writer).
                // Hop to read the committed post-change value and re-arm, which
                // also matches the run-loop hop the surviving Combine consumers
                // had.
                Task { @MainActor in
                    guard let handle, !handle.cancelled else { return }
                    onChange()
                    handle.reArm()
                }
            }
        }
        handle.reArm()
        return handle
    }
}

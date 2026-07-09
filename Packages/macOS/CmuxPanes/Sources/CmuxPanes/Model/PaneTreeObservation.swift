internal import Observation

/// A cancellable handle for a re-arming ``PaneTreeModel`` observation. Holding
/// it keeps the watch armed; dropping it (or calling ``cancel()``) stops the
/// re-arm so no further change handlers fire.
///
/// The handle is the lifetime owner the legacy `panelsPublisher`
/// `CurrentValueSubject` bridge used an `AnyCancellable` for: a subscriber
/// stores it for as long as it wants the callback, and releasing it tears the
/// watch down. Cancellation is idempotent.
///
/// This mirrors `CmuxWorkspaces`'s `WorkspacesObservation` handle, the
/// established `@Observable` replacement for the retired per-property
/// `CurrentValueSubject` bridges.
@MainActor
public final class PaneTreeObservation {
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

extension PaneTreeModel {
    /// Observes ``panels`` and invokes `onChange` after every mutation of the
    /// registry, including assignments of an equal value.
    ///
    /// This is the `@Observable` replacement for an internal subscriber of the
    /// legacy `Workspace.panelsPublisher` `CurrentValueSubject` bridge. Two
    /// timing differences from that bridge, both behavior-faithful for an
    /// idempotent debounced scheduler that only cares *that* panels changed:
    ///
    /// - **Delivered after the change commits, not during `willSet`.** The
    ///   bridge sent the new value from the `panels` `willSet`; this delivers
    ///   `onChange` on a `MainActor` hop after the mutation, so `panels` already
    ///   reads the new value inside `onChange`.
    /// - **Optional replay on subscribe.** `CurrentValueSubject` delivered the
    ///   current value immediately to a new `.sink`. Set `fireImmediately` to
    ///   reproduce that initial delivery for a subscriber that relied on it;
    ///   otherwise `onChange` fires only on the *next* change.
    ///
    /// Equal-value parity is preserved: the `@Observable` macro records a
    /// mutation on every set, so `onChange` fires on an equal re-assignment just
    /// as the bridge's `.send` did.
    ///
    /// The returned ``PaneTreeObservation`` owns the watch's lifetime; store it
    /// for as long as the callback is wanted and drop or
    /// ``PaneTreeObservation/cancel()`` it to stop.
    public func observePanels(
        fireImmediately: Bool = false,
        _ onChange: @escaping @MainActor () -> Void
    ) -> PaneTreeObservation {
        let handle = PaneTreeObservation()
        handle.armOnce = { [weak handle, weak self] in
            guard let self else { return }
            withObservationTracking {
                _ = self.panels
            } onChange: {
                // Observation delivers `onChange` at `willSet` time on the
                // mutating context (the MainActor; the model's single writer).
                // Hop to read the committed post-change value and re-arm.
                Task { @MainActor in
                    guard let handle, !handle.cancelled else { return }
                    onChange()
                    handle.reArm()
                }
            }
        }
        handle.reArm()
        if fireImmediately {
            onChange()
        }
        return handle
    }
}

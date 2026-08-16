public import Foundation
internal import os

/// (B) ExternalHover — the bounded synchronous acceptance-boundary value
/// a `HoverCallbackMirror` publishes/serves.
///
/// `lifetimeID`/`hoverEventID`/`eligible`/`visible` are updated together as
/// ONE value by `publish(_:)` — never as separate field writes — so a
/// reader can never observe an `hoverEventID` that's newer than the
/// identity/eligibility it's paired with (a torn read).
public struct HoverCallbackSnapshot: Sendable, Equatable {
    public var lifetimeID: RuntimeSurfaceLifetimeID?
    public var hoverEventID: UInt64
    public var eligible: Bool
    public var visible: Bool

    public init(
        lifetimeID: RuntimeSurfaceLifetimeID? = nil,
        hoverEventID: UInt64 = 0,
        eligible: Bool = false,
        visible: Bool = false
    ) {
        self.lifetimeID = lifetimeID
        self.hoverEventID = hoverEventID
        self.eligible = eligible
        self.visible = visible
    }
}

/// (B) ExternalHover — per-surface snapshot mirror.
///
/// Lock carve-out: Ghostty's native `MOUSE_OVER_LINK` callback fires
/// synchronously on the renderer thread and cannot `await`, so it cannot
/// read a main-actor-isolated property directly. Main (the AppKit event
/// path, wired in a later pass) is the sole writer, via `publish(_:)`,
/// every time an input serial (`hoverEventID`) or lifecycle/eligibility
/// fact changes — always BEFORE forwarding the same event to
/// `ghostty_surface_mouse_pos`, so a synchronously-fired native callback
/// for that event can never observe a stale `hoverEventID`. The native
/// callback, and the `ExternalHoverWorkService` actor's own
/// acceptance-boundary checks, are the only readers, via
/// `captureHoverCallbackSnapshot()`.
///
/// The lock section inside `publish`/`captureHoverCallbackSnapshot` does
/// exactly one thing — a value copy — and must never do main-thread
/// dispatch, filesystem probes, actor calls, Ghostty API calls, or
/// logging. Both are O(1) and never suspend.
public final class HoverCallbackMirror: Sendable {
    private let state = OSAllocatedUnfairLock<HoverCallbackSnapshot>(
        initialState: HoverCallbackSnapshot()
    )

    public init() {}

    /// Replaces the whole snapshot atomically. Called by main only.
    public func publish(_ snapshot: HoverCallbackSnapshot) {
        state.withLock { $0 = snapshot }
    }

    /// The one accessor a synchronous native callback, or the work
    /// actor's acceptance-boundary check, may call.
    public func captureHoverCallbackSnapshot() -> HoverCallbackSnapshot {
        state.withLock { $0 }
    }
}

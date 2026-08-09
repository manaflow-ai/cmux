public import Foundation
public import GhosttyKit
public import CmuxTerminalCore

/// (B) ExternalHover — one coalesced hover-recompute request, built
/// entirely on the main actor from a single snapshot of input, then
/// handed to `ExternalHoverWorkService` by value.
///
/// The actor never reads `GhosttyNSView`/`TerminalSurface` state directly
/// — everything it needs is IN this struct. Deliberately carries the raw
/// `surface` pointer as a value (not a pre-acquired lease): review
/// Blocking 4 requires the work actor to acquire its OWN lease
/// just-in-time, immediately before each bounded C access, and release it
/// immediately after — never hold one across the actor-queue wait or a
/// filesystem probe. `@unchecked Sendable` for the same reason as
/// `TerminalSurfaceRuntimeScreenTailRequest`: the raw pointer's validity
/// is the teardown coordinator's responsibility to enforce via the lease,
/// not the type system's.
public struct ExternalHoverWorkRequest: @unchecked Sendable {
    public let lifetimeID: RuntimeSurfaceLifetimeID
    public let surface: ghostty_surface_t
    /// == the `hoverEventID` published to `mirror` at the moment this
    /// request was built — the acceptance-boundary checks compare against
    /// `mirror`'s CURRENT value, never trust this alone.
    public let requestGeneration: UInt64
    public let cell: ExternalHoverGridCell
    /// Total rows in the surface's viewport, for clamping the bounded
    /// read window at the top/bottom edge.
    public let viewportRowCount: UInt32
    public let cwd: String
    public let mirror: HoverCallbackMirror
    public let coordinator: ExternalHoverOwnerCoordinator
    /// (C) ExternalHover diagnostics — the process-local, debug-only
    /// monotonic id (design-hover-diagnostics-v4-final.md §1) identifying
    /// which `GhosttyNSView` this request came from, so a single shared
    /// debug log with multiple surfaces can disambiguate `event` values
    /// that would otherwise collide across surfaces. Never crosses into
    /// Ghostty — `host_event_id` on the C ABI is `requestGeneration`
    /// alone.
    public let surfaceSerial: UInt64

    public init(
        lifetimeID: RuntimeSurfaceLifetimeID,
        surface: ghostty_surface_t,
        requestGeneration: UInt64,
        cell: ExternalHoverGridCell,
        viewportRowCount: UInt32,
        cwd: String,
        mirror: HoverCallbackMirror,
        coordinator: ExternalHoverOwnerCoordinator,
        surfaceSerial: UInt64
    ) {
        self.lifetimeID = lifetimeID
        self.surface = surface
        self.requestGeneration = requestGeneration
        self.cell = cell
        self.viewportRowCount = viewportRowCount
        self.cwd = cwd
        self.mirror = mirror
        self.coordinator = coordinator
        self.surfaceSerial = surfaceSerial
    }
}

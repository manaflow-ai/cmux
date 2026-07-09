public import CoreGraphics
public import CmuxTerminalCore

/// The app-target seam ``TerminalWordPathRoutingCoordinator`` calls back through
/// for the cmd-click word-path resolution inputs that must stay on the
/// `GhosttyNSView` god type: the resolved working directory, the pointer-anchored
/// visible-grid snapshot, the live `ghostty_surface_quicklook_word` extraction,
/// and the viewport-offset visible-grid snapshot.
///
/// The `ghostty_surface_t` handle, the `TerminalController` text-snapshot reader,
/// the `Workspace`/`TerminalSurface` references, and the cell/bounds geometry all
/// stay app-side: the conformer performs each app-coupled read and hands the
/// coordinator only `Sendable` value results (resolved paths and the
/// ``TerminalQuicklookWordSnapshot``). The coordinator owns the routing decision
/// (which source wins) and the `#if DEBUG` cmd-click overrides.
///
/// Isolation design: the conformer (`GhosttyNSView`) is a non-isolated `NSView`
/// whose word-path methods run on the main thread by convention (mouse/hover
/// event callbacks), so this protocol is non-isolated and the coordinator holds
/// the host weakly, mirroring the sibling ``TerminalAppearanceHosting`` drain. No
/// member suspends; every call is a synchronous main-thread forward.
public protocol TerminalWordPathHosting: AnyObject {
    /// The working directory cmd-click paths resolve against, or `nil` when the
    /// surface/workspace guards fail (no live surface, no owning workspace, or a
    /// remote terminal surface).
    func wordPathWorkingDirectory() -> String?

    /// The pointer-anchored visible-grid resolution for the requested point,
    /// resolved against `cwd`. The conformer maps the point to a cell and reads
    /// the visible terminal text; this is the source tied directly to the click
    /// location.
    func pointSnapshotWordPath(at requestedPoint: CGPoint?, cwd: String) -> WordPathResolution?

    /// The live Ghostty QuickLook-word snapshot, or `nil` when the runtime
    /// reported no word under the cursor.
    func quicklookWordSnapshot() -> TerminalQuicklookWordSnapshot?

    /// The viewport-offset visible-grid resolution for the given offset, resolved
    /// against `cwd`.
    func viewportWordPath(viewportOffsetStart: Int, cwd: String) -> WordPathResolution?
}

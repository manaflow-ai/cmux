public import AppKit

/// The window identity and lifecycle seam the app target routes through to
/// learn which main windows exist and to be told the instant one closes.
///
/// This is the keystone that lets per-window state stop living in one
/// `AppDelegate`-owned aggregate. The conformer (``WindowCoordinator``) owns
/// ONLY window identity and lifecycle: the set of live ``WindowID``s, the
/// `NSWindow` handle for each, and a single window-closed broadcast. It owns no
/// tabs, sidebar, focus, file-explorer, or config state. Each domain keeps its
/// own `[WindowID: Model]` and drops a window's slice when it observes the
/// closed event on ``windowClosed`` (owner ruling 2026-06-18: no per-window
/// aggregate; per-window state is domain-owned and `WindowID`-keyed).
///
/// `@MainActor` because window registration and teardown originate on the main
/// thread from AppKit callbacks, so the state lives where its callers live and
/// no bridging is needed (mirrors the SocketControlServer isolation ruling).
@MainActor
public protocol WindowManaging: AnyObject {
    /// The identifiers of every main window currently registered, in no
    /// guaranteed order.
    var windowIds: Set<WindowID> { get }

    /// Registers `window` under `id`, taking over observation of the window's
    /// close so that closing it yields `id` on ``windowClosed``.
    ///
    /// Re-registering an already-known `id` rebinds it to `window` (the app
    /// reuses a `WindowID` when a window is recreated during restore); the
    /// previous close observation for that id is replaced.
    func register(_ window: NSWindow, id: WindowID)

    /// Drops `id` from the registry without emitting a close event, used when
    /// the app explicitly tears a window down outside the AppKit close path.
    /// Returns the `NSWindow` that was registered for `id`, if any.
    @discardableResult
    func unregister(_ id: WindowID) -> NSWindow?

    /// The live `NSWindow` registered for `id`, if it still exists.
    func window(for id: WindowID) -> NSWindow?

    /// The ``WindowID`` registered for `window`, if any.
    func id(for window: NSWindow) -> WindowID?

    /// A broadcast of window-closed events, one element per window that closes
    /// (or is unregistered through the close path). Each domain subscribes once
    /// at startup and drops the closing window's per-window slice.
    ///
    /// `nonisolated` so a domain can start a detached `for await` loop without
    /// hopping onto the main actor merely to obtain the stream; the values it
    /// yields (``WindowID``) are `Sendable`.
    nonisolated var windowClosed: AsyncStream<WindowID> { get }
}

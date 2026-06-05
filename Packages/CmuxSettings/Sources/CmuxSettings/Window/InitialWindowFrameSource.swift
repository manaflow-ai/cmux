import CoreGraphics

/// The chosen source for a new main window's initial geometry.
///
/// ``WindowOpenSizeSettings/resolveInitialFrameSource(fixedContentSize:restoredFrame:sourceWindowFrame:persistedGeometryFrame:)``
/// returns one of these cases so the AppKit layer can decide how to size and
/// position the window without re-implementing the precedence rules. The
/// precedence (highest first) is:
///
/// 1. ``restored(_:)`` — a per-window frame from full session restore. This
///    always wins so restoring a saved multi-window layout keeps each window's
///    exact geometry, even when the fixed-size option is on.
/// 2. ``fixedSize(_:)`` — the user's configured `window.width` × `window.height`
///    from ``WindowOpenSizeSettings``. Overrides the source-window match and the
///    persisted last-window geometry for every freshly created window.
/// 3. ``sourceWindow(_:)`` — copy the frame of the window the new one was
///    spawned from (e.g. Cmd-Shift-N).
/// 4. ``persistedGeometry(_:)`` — the last-used window frame persisted across
///    launches.
/// 5. ``fallbackDefault`` — no signal available; use the built-in default size.
public enum InitialWindowFrameSource: Equatable, Sendable {
    /// Use a per-window frame restored from a saved session.
    case restored(CGRect)

    /// Open at the user's configured fixed content size.
    case fixedSize(CGSize)

    /// Match the frame of the window the new window was spawned from.
    case sourceWindow(CGRect)

    /// Reuse the last-used window frame persisted across launches.
    case persistedGeometry(CGRect)

    /// No geometry signal is available; use the built-in default size.
    case fallbackDefault
}

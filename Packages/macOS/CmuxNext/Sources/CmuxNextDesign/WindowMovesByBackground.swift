public import AppKit

/// A window a press on any empty space moves, as a title bar does (the floating Chief's, a launcher): its pages
/// report such presses anywhere, not only in the window's top row.
///
/// ```swift
/// final class LauncherPanel: NSPanel, WindowMovesByBackground {}
/// ```
@MainActor
public protocol WindowMovesByBackground: NSWindow {}

public import AppKit

/// A surface view whose key equivalents are its own while it is first responder: the terminal (its
/// Ghostty keybinds) and the page hosts (their page's keys). The key router hands a chord it decided
/// straight to such a first responder instead of AppKit's walk over every view of the window (Chrome's
/// `CommandDispatcherTarget`, ui/base/cocoa/command_dispatcher.mm).
///
/// Each surface adopts it in its own module, so the router names no surface type: a surface that only a
/// Debug or bench build compiles (the development remote browser page) adopts it there, and a Release
/// build still compiles the router.
///
/// ```swift
/// if firstResponder is any KeyEquivalentOwningSurface { return firstResponder }
/// ```
@MainActor
public protocol KeyEquivalentOwningSurface: NSView {}

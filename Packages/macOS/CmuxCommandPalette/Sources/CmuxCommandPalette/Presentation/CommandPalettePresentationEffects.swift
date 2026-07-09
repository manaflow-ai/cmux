internal import Foundation

/// The app-coupled side effects a ``CommandPalettePresentationCoordinator`` fires
/// while it drives the per-window palette state machine.
///
/// The coordinator owns the window-agnostic request / visibility / escape-suppression
/// state (keyed by `WindowID`), but DEBUG logging is the one effect it cannot perform
/// itself, so it is injected as a `@MainActor` closure (a no-op in release; the app
/// target wires it to `cmuxDebugLog`).
///
/// The other side effects — clearing focused-browser focus mode and posting the
/// `cmux.*` notifications — target a live `NSWindow` / `NotificationCenter`, so they are
/// passed per call as closures and never enter this struct. That keeps the coordinator
/// free of any AppKit dependency while preserving the original `NSWindow`-keyed
/// behavior exactly.
public struct CommandPalettePresentationEffects: Sendable {
    /// Emits a DEBUG diagnostic line.
    public var log: @MainActor (_ message: String) -> Void

    /// Creates an effects bundle.
    public init(log: @escaping @MainActor (_ message: String) -> Void) {
        self.log = log
    }

    /// An effects bundle whose `log` does nothing, for tests that exercise the pure
    /// state machine without app-target side effects.
    public static let noop = CommandPalettePresentationEffects(log: { _ in })
}

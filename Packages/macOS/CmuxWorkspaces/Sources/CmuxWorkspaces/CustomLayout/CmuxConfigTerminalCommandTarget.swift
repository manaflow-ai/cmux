import Foundation

/// Where a `cmux.json` terminal command runs: the focused terminal, or a fresh
/// tab spawned in the current pane.
///
/// Encoded as a bare string (`currentTerminal` / `newTabInCurrentPane`) in the
/// config wire schema. ``defaultForActions`` is the target applied to a
/// configured action that does not specify one.
public enum CmuxConfigTerminalCommandTarget: String, Codable, Sendable, Hashable {
    /// Run in the currently focused terminal surface.
    case currentTerminal
    /// Open a new tab in the current pane and run there.
    case newTabInCurrentPane

    /// The target used by configured actions that omit an explicit target.
    public static let defaultForActions: CmuxConfigTerminalCommandTarget = .newTabInCurrentPane
}

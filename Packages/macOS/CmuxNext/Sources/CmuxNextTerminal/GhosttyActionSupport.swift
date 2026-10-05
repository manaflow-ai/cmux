import Foundation

/// The Ghostty keybind actions cmux does not run, and why (GHOSTTY-CONFIG
/// diagnostics; the keybindings lead owns this table, the R92 diagnostics
/// read it). Keyed by the action name before any `:` parameter. Every other
/// window, tab and split action routes to the cmux catalog
/// (`TerminalHostActionRoute`); a test keeps the two in step.
public nonisolated struct GhosttyActionSupport: Sendable {
    public init() {}

    public static let unsupported: [String: GhosttyUnsupported] = [:]
}

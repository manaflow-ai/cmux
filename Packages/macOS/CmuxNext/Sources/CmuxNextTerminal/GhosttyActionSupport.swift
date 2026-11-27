import Foundation

/// The Ghostty keybind actions cmux does not run, and why (GHOSTTY-CONFIG
/// diagnostics; the keybindings lead owns this table, the R92 diagnostics
/// read it). Keyed by the action name before any `:` parameter. Every other
/// window, tab and split action routes to the cmux catalog
/// (`TerminalHostActionRoute`); a test keeps the two in step.
public nonisolated struct GhosttyActionSupport: Sendable {
    public init() {}

    public static let unsupported: [String: GhosttyUnsupported] = [
        // No equivalent in cmux (coordinator decisions C1, H1).
        "inspector": GhosttyUnsupported(.notApplicable),
        "redo": GhosttyUnsupported(.notApplicable),
        "toggle_background_opacity": GhosttyUnsupported(.notApplicable),
        "float_window": GhosttyUnsupported(.notApplicable),
        "reset_window_size": GhosttyUnsupported(.notApplicable),
        // cmux's window.titlebar setting owns the window frame (R92 decision 1).
        "toggle_window_decorations": GhosttyUnsupported(.superseded, replacement: "window.titlebar"),
        // The quick terminal is its own slice (I1).
        "toggle_quick_terminal": GhosttyUnsupported(.later),
    ]
}

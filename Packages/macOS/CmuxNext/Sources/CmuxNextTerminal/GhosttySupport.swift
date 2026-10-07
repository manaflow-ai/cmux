import Foundation

/// Why cmux does not apply a Ghostty config key or keybind action
/// (R92 diagnostics; plans/cmux-next/ghostty-config.md).
public nonisolated enum GhosttySupportReason: String, Sendable, Hashable, CaseIterable {
    /// A cmux feature does this instead (`GhosttyUnsupported.replacement`).
    case superseded
    /// It has no meaning in cmux.
    case notApplicable = "not-applicable"
    /// cmux will apply it; not yet.
    case later
}

/// One Ghostty key or action cmux does not apply, and why.
public nonisolated struct GhosttyUnsupported: Sendable, Hashable {
    public var reason: GhosttySupportReason
    /// The cmux setting key or action id that replaces it (superseded only).
    public var replacement: String?

    public init(_ reason: GhosttySupportReason, replacement: String? = nil) {
        self.reason = reason
        self.replacement = replacement
    }
}

/// The Ghostty config keys cmux does not apply. Every other key applies
/// (the inventory, plans/cmux-next/ghostty-config-inventory.md). The keybind
/// actions are the keybindings lead's `GhosttyActionSupport`.
public nonisolated struct GhosttyKeySupport: Sendable {
    public init() {}

    private static let later = GhosttyUnsupported(.later)
    private static let notApplicable = GhosttyUnsupported(.notApplicable)
    private static let titlebar = GhosttyUnsupported(.superseded, replacement: "window.titlebar")

    public static let unsupported: [String: GhosttyUnsupported] = {
        var table: [String: GhosttyUnsupported] = [:]
        for key in [
            // Pane chrome and splits.
            "unfocused-split-opacity", "unfocused-split-fill", "split-divider-color", "split-preserve-zoom",
            // Processes: the daemon spawns them with cmux's own rules.
            "command", "initial-command", "env", "input", "wait-after-command", "abnormal-command-exit-runtime",
            "working-directory", "window-inherit-working-directory", "tab-inherit-working-directory",
            "split-inherit-working-directory",
            "notify-on-command-finish", "notify-on-command-finish-action", "notify-on-command-finish-after",
            // Terminal surface.
            "scrollbar", "link-previews", "window-inherit-font-size", "title-report", "osc-color-report-format",
            "vt-window-resize-allowed", "enquiry-response", "progress-style",
            "resize-overlay", "resize-overlay-position", "resize-overlay-duration", "focus-follows-mouse",
            // Windows and app lifecycle.
            "maximize", "fullscreen", "window-height", "window-width", "window-position-x", "window-position-y",
            "window-save-state", "confirm-close-surface", "quit-after-last-window-closed",
            "quit-after-last-window-closed-delay", "command-palette-entry",
            "macos-auto-secure-input", "macos-secure-input-indication", "window-new-tab-position",
            // The quick terminal is its own slice.
            "quick-terminal-position", "quick-terminal-size", "quick-terminal-screen",
            "quick-terminal-animation-duration", "quick-terminal-autohide", "quick-terminal-space-behavior",
        ] { table[key] = later }
        for key in [
            "window-decoration", "window-title-font-family", "macos-titlebar-style", "macos-titlebar-proxy-icon",
            "macos-window-buttons",
        ] { table[key] = titlebar }
        table["window-theme"] = GhosttyUnsupported(.superseded, replacement: "appearance.theme")
        for key in [
            "window-step-resize", "initial-window", "undo-timeout", "macos-non-native-fullscreen",
            "macos-dock-drop-behavior", "macos-window-shadow", "macos-hidden",
        ] { table[key] = notApplicable }
        return table
    }()
}

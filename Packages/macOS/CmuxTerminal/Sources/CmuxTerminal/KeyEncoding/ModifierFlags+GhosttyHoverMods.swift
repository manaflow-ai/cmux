public import AppKit
public import GhosttyKit
#if DEBUG
internal import CmuxTestSupport
#endif

extension NSEvent.ModifierFlags {
    /// Translates these modifier flags into libghostty mouse mods for the
    /// hover/link-update path, optionally dropping Command when a Command-hover
    /// path-resolution should be suppressed (e.g. over an active selection).
    ///
    /// The `#if DEBUG` UITest sink records suppressed Command-hover events for
    /// the command-hover diagnostics capture file; it is data-driven and a
    /// no-op in production launches.
    public func terminalGhosttyHoverMods(
        suppressCommandPathHover: Bool
    ) -> ghostty_input_mods_e {
        let effectiveFlags = suppressCommandPathHover ? subtracting(.command) : self
#if DEBUG
        if suppressCommandPathHover, contains(.command) {
            _ = UITestCaptureSink().mutateJSONObjectIfConfigured(
                envKey: "CMUX_UI_TEST_CMD_HOVER_DIAGNOSTICS_PATH"
            ) { payload in
                payload["suppressed_command_hover_count"] = (payload["suppressed_command_hover_count"] as? Int ?? 0) + 1
            }
        }
#endif
        return effectiveFlags.terminalGhosttyMouseMods
    }
}

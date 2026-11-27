public import Foundation

/// The outcome of a synchronous v1 panel-targeted sidebar write (`report_ports`
/// / `report_pwd` / `report_shell_state` / `report_tty` / `ports_kick` /
/// `clear_ports`), preserving each command's distinct legacy error strings and
/// their legacy ordering (tab resolution and metadata pruning run before the
/// panel-argument checks, so the panel checks live app-side too).
public enum ControlSidebarPanelWriteResolution: Sendable, Equatable {
    /// The target tab could not be resolved.
    case tabNotFound
    /// The `--panel`/`--surface` option was present but empty.
    case missingPanelArg
    /// The `--panel`/`--surface` option was not a UUID (carries the raw
    /// argument for the legacy error string).
    case invalidPanelArg(String)
    /// No explicit panel id and no focused surface to fall back to.
    case noFocusedPanel
    /// The resolved panel id is not a live surface of the tab.
    case panelNotFound(UUID)
    /// The write was applied.
    case done
}

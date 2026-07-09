public import Foundation
public import GhosttyKit

/// The app-target seam ``GhosttyActionDispatchCoordinator`` calls back through
/// for the cold (non-per-frame) ghostty action effects that must stay on the
/// `GhosttyApp` god type in `GhosttyTerminalView.swift`.
///
/// The coordinator owns only the `action.tag` → host-call decision tree for the
/// cold app-target actions (`RELOAD_CONFIG`, `CONFIG_CHANGE`, `COLOR_CHANGE`,
/// `RING_BELL`, `DESKTOP_NOTIFICATION`) plus the surface `SHOW_CHILD_EXITED`
/// action. Every side effect — the background action log, the
/// `TerminalNotificationStore` write, the bell, the configuration reload, the
/// app color change, the key-window backdrop apply, and the child-exit panel
/// close — stays app-side behind this protocol. The notification title/body are
/// resolved to plain `String`s app-side (including the localized "Terminal"
/// fallback); the coordinator only forwards the raw payload strings it extracted
/// from the ghostty C structs.
///
/// The `ghostty_action_s` / `ghostty_target_s` / `ghostty_action_color_change_s`
/// C payloads cross this boundary only where the existing effect already
/// consumed them (the action log and the app color change), mirroring the
/// sibling ``TerminalAppearanceHosting`` which crosses `ghostty_color_scheme_e`.
/// No `ghostty_app_t` / `ghostty_surface_t` handle ever crosses.
///
/// Isolation design: the conformer (`GhosttyApp`) is a non-isolated class whose
/// action callbacks arrive on the ghostty runtime thread and hop to main through
/// the conformer's own `performOnMain` / `DispatchQueue.main`. This protocol is
/// therefore non-isolated and every member is a synchronous forward; the
/// coordinator is a stateless value passed the host per call.
public protocol GhosttyActionHosting: AnyObject {
    /// Emits the background action-event log line for the cold app-target
    /// reload/config/color triplet (target-less, surface-less).
    func dispatchLogColdConfigAction(_ action: ghostty_action_s, target: ghostty_target_s)

    /// Records a desktop-notification action against the focused tab/surface,
    /// resolving the localized fallback title app-side. Returns whether the
    /// action was handled (matching the legacy `performOnMain` result).
    func dispatchAppDesktopNotification(title: String, body: String) -> Bool

    /// Rings the terminal bell on the main thread.
    func dispatchAppRingBell()

    /// Reloads the app configuration for a `reload_config` app-target action,
    /// honoring the reentrancy guard on the main thread.
    func dispatchAppReloadConfig(soft: Bool)

    /// Applies an app-target color change on the main thread.
    func dispatchAppColorChange(_ change: ghostty_action_color_change_s)

    /// Resolves the runtime color scheme and reapplies the key-window backdrop
    /// for an app-target `config_change` action.
    func dispatchAppConfigChange()

    /// Closes the panel whose child (shell) exited, reporting the action handled
    /// so ghostty does not print its fallback prompt.
    func dispatchShowChildExited(tabId: UUID?, surfaceId: UUID?)
}

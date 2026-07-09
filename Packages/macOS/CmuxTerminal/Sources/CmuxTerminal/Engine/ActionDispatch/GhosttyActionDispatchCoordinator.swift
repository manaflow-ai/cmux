public import Foundation
public import GhosttyKit

/// The cold (non-per-frame) ghostty action dispatcher drained out of
/// `GhosttyApp.handleAction(target:action:)` in `GhosttyTerminalView.swift`.
///
/// It owns the `action.tag` → host-call decision tree for the app-target cold
/// actions and the surface `SHOW_CHILD_EXITED` action, extracting the Sendable
/// decisions (the desktop-notification title/body strings, the `reload_config`
/// soft flag, the resolved tab/surface ids) from the ghostty C structs and
/// forwarding every side effect to the app through ``GhosttyActionHosting``. The
/// per-frame render/scroll/cell-size branches and the remaining surface
/// dispatch stay inline on `GhosttyApp`; this type is only reached for the cold
/// branches.
///
/// It is stateless: the host is passed per call and the same `Bool` the legacy
/// inline dispatch returned is returned here, so the C runtime callback keeps
/// observing byte-identical results.
public struct GhosttyActionDispatchCoordinator {
    public init() {}

    /// Dispatches a cold app-target (non-surface) ghostty action, returning the
    /// same `Bool` the legacy inline app-target branch returned (`false` for an
    /// unhandled tag).
    public func dispatchAppTargetAction(
        _ action: ghostty_action_s,
        target: ghostty_target_s,
        host: any GhosttyActionHosting
    ) -> Bool {
        if action.tag == GHOSTTY_ACTION_RELOAD_CONFIG ||
            action.tag == GHOSTTY_ACTION_CONFIG_CHANGE ||
            action.tag == GHOSTTY_ACTION_COLOR_CHANGE {
            host.dispatchLogColdConfigAction(action, target: target)
        }

        if action.tag == GHOSTTY_ACTION_DESKTOP_NOTIFICATION {
            let actionTitle = action.action.desktop_notification.title
                .flatMap { String(cString: $0) } ?? ""
            let actionBody = action.action.desktop_notification.body
                .flatMap { String(cString: $0) } ?? ""
            return host.dispatchAppDesktopNotification(title: actionTitle, body: actionBody)
        }

        if action.tag == GHOSTTY_ACTION_RING_BELL {
            host.dispatchAppRingBell()
            return true
        }

        if action.tag == GHOSTTY_ACTION_RELOAD_CONFIG {
            let soft = action.action.reload_config.soft
            host.dispatchAppReloadConfig(soft: soft)
            return true
        }

        if action.tag == GHOSTTY_ACTION_COLOR_CHANGE {
            host.dispatchAppColorChange(action.action.color_change)
            return true
        }

        if action.tag == GHOSTTY_ACTION_CONFIG_CHANGE {
            host.dispatchAppConfigChange()
            return true
        }

        return false
    }

    /// Dispatches the surface `SHOW_CHILD_EXITED` action, always reporting the
    /// action handled so ghostty does not print its fallback prompt.
    public func dispatchSurfaceChildExited(
        tabId: UUID?,
        surfaceId: UUID?,
        host: any GhosttyActionHosting
    ) -> Bool {
        host.dispatchShowChildExited(tabId: tabId, surfaceId: surfaceId)
        return true
    }
}

internal import Foundation

/// The residual v1 line-protocol dispatch for the surface listing/focus, the
/// terminal-input (`send` / `send_key` / `send_surface` / `send_key_surface`,
/// plus the DEBUG-only `send_workspace`), the notification, the app-focus, the
/// `read_screen`, and the `help` commands — the byte-faithful twins of the
/// former `TerminalController` v1 cases.
///
/// These commands have no exact v2 counterpart that this coordinator could
/// re-shape (the v2 surface/notification methods take JSON params and return
/// JSON results, while these take positional `<id|idx>` / pipe-delimited
/// arguments and return flat reply lines). So the irreducibly app-coupled
/// bodies stay app-resident behind the per-domain seams, and each case here
/// forwards the raw `args` to its witness and returns the witness's raw reply
/// verbatim — exactly the ``handleDebugV1`` shape. The lone in-coordinator logic
/// is `set_app_focus`, whose `active`/`inactive`/`clear` token table is pure
/// parsing that resolves to the existing ``ControlAppFocusContext`` witnesses.
extension ControlCommandCoordinator {
    /// The surface-domain slice of the seam (a typed view of ``context``).
    var surfaceContext: (any ControlSurfaceContext)? {
        context
    }

    /// The notification-domain slice of the seam (a typed view of ``context``).
    var notificationContext: (any ControlNotificationContext)? {
        context
    }

    /// The app-focus-domain slice of the seam (a typed view of ``context``).
    var appFocusContext: (any ControlAppFocusContext)? {
        context
    }

    /// Dispatches the v1 surface/send/notify/app-focus/read_screen/help commands
    /// this coordinator owns; returns `nil` for anything else so the app's legacy
    /// v1 dispatcher can fall through.
    ///
    /// - Parameters:
    ///   - command: The lowercased v1 command token.
    ///   - args: The raw argument remainder of the command line.
    /// - Returns: The raw reply line, or `nil` if not owned here.
    public func handleSurfaceSendNotifyV1(command: String, args: String) -> String? {
        switch command {
        case "list_surfaces":
            return surfaceContext?.controlSurfaceListV1(tabArg: args)
                ?? Self.surfaceSendNotifyContextUnavailableResponse
        case "focus_surface":
            return surfaceContext?.controlSurfaceFocusV1(arg: args)
                ?? Self.surfaceSendNotifyContextUnavailableResponse
        case "send":
            return surfaceContext?.controlSurfaceSendInputV1(text: args)
                ?? Self.surfaceSendNotifyContextUnavailableResponse
        case "send_key":
            return surfaceContext?.controlSurfaceSendKeyV1(keyName: args)
                ?? Self.surfaceSendNotifyContextUnavailableResponse
        case "send_surface":
            return surfaceContext?.controlSurfaceSendInputToSurfaceV1(args: args)
                ?? Self.surfaceSendNotifyContextUnavailableResponse
        case "send_key_surface":
            return surfaceContext?.controlSurfaceSendKeyToSurfaceV1(args: args)
                ?? Self.surfaceSendNotifyContextUnavailableResponse
        case "notify":
            return notificationContext?.controlNotifyCurrentV1(args: args)
                ?? Self.surfaceSendNotifyContextUnavailableResponse
        case "notify_surface":
            return notificationContext?.controlNotifySurfaceV1(args: args)
                ?? Self.surfaceSendNotifyContextUnavailableResponse
        case "notify_target":
            return notificationContext?.controlNotifyTargetV1(args: args)
                ?? Self.surfaceSendNotifyContextUnavailableResponse
        case "notify_target_async":
            return notificationContext?.controlNotifyTargetQueuedV1(args: args)
                ?? Self.surfaceSendNotifyContextUnavailableResponse
        case "list_notifications":
            return notificationContext?.controlNotificationsListV1()
                ?? Self.surfaceSendNotifyContextUnavailableResponse
        case "clear_notifications":
            return notificationContext?.controlNotificationsClearV1(args: args)
                ?? Self.surfaceSendNotifyContextUnavailableResponse
        case "set_app_focus":
            return setAppFocusOverrideV1(args)
        case "simulate_app_active":
            guard let appFocusContext else {
                return Self.surfaceSendNotifyContextUnavailableResponse
            }
            appFocusContext.controlSimulateAppActive()
            return "OK"
        case "read_screen":
            return surfaceContext?.controlSurfaceReadScreenV1(args: args)
                ?? Self.surfaceSendNotifyContextUnavailableResponse
        case "help":
            return systemContext?.controlHelpTextV1()
                ?? Self.surfaceSendNotifyContextUnavailableResponse
#if DEBUG
        case "send_workspace":
            return surfaceContext?.controlSurfaceSendInputToWorkspaceV1(args: args)
                ?? Self.surfaceSendNotifyContextUnavailableResponse
#endif
        default:
            return nil
        }
    }

    /// The v1 `set_app_focus` body: parses the `active`/`inactive`/`clear` token
    /// table (the legacy `setAppFocusOverride`) and applies the resolved override
    /// through the existing ``ControlAppFocusContext`` witness. The token mapping
    /// is pure, so it lives in the coordinator; only the `AppFocusState` write is
    /// behind the seam.
    ///
    /// - Parameter arg: The raw mode argument.
    /// - Returns: `"OK"` on a recognized token, or the legacy error line.
    func setAppFocusOverrideV1(_ arg: String) -> String {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let override: Bool?
        switch trimmed {
        case "active", "1", "true":
            override = true
        case "inactive", "0", "false":
            override = false
        case "clear", "none", "":
            override = nil
        default:
            return "ERROR: Expected active, inactive, or clear"
        }
        guard let appFocusContext else {
            return Self.surfaceSendNotifyContextUnavailableResponse
        }
        appFocusContext.controlSetAppFocusOverride(override)
        return "OK"
    }

    /// The reply returned when the control context is not wired (unreachable in
    /// practice — the composition owner wires it during init). Matches the
    /// ``handleDebugV1`` unavailable-response shape.
    static let surfaceSendNotifyContextUnavailableResponse = "ERROR: control context unavailable"
}

import CmuxControlSocket
import Foundation

/// The v1 line-protocol surface/send/notify/help witnesses: thin forwards to the
/// still-app-resident v1 string bodies (`listSurfaces`, `focusSurface`,
/// `sendInput`, `sendKey`, `sendInputToSurface`, `sendKeyToSurface`,
/// `sendInputToWorkspace`, `readScreenText`, `notifyCurrent`, `notifySurface`,
/// `notifyTarget`, `notifyTargetQueued`, `listNotifications`,
/// `clearNotifications`, `helpText`).
///
/// These bodies are irreducibly app-coupled — they read live `TabManager` /
/// `Workspace` / `TerminalPanel` state through `v2MainSync`, deliver through
/// `TerminalMutationBus` / `TerminalNotificationStore`, and the help text is
/// frozen app-resident copy with a DEBUG/release split. So
/// ``ControlCommandCoordinator/handleSurfaceSendNotifyV1(command:args:)`` owns
/// only the dispatch; each witness returns the legacy body's raw reply line
/// verbatim, keeping the wire output byte-identical. The matching
/// ``ControlAppFocusContext`` witnesses live in
/// `TerminalController+ControlAppFocusContext.swift`.
extension TerminalController {
    func controlSurfaceListV1(tabArg: String) -> String { listSurfaces(tabArg) }

    func controlSurfaceFocusV1(arg: String) -> String { focusSurface(arg) }

    func controlSurfaceSendInputV1(text: String) -> String { sendInput(text) }

    func controlSurfaceSendKeyV1(keyName: String) -> String { sendKey(keyName) }

    func controlSurfaceSendInputToSurfaceV1(args: String) -> String { sendInputToSurface(args) }

    func controlSurfaceSendKeyToSurfaceV1(args: String) -> String { sendKeyToSurface(args) }

    #if DEBUG
    func controlSurfaceSendInputToWorkspaceV1(args: String) -> String { sendInputToWorkspace(args) }
    #endif

    func controlSurfaceReadScreenV1(args: String) -> String { readScreenText(args) }

    func controlNotifyCurrentV1(args: String) -> String { notifyCurrent(args) }

    func controlNotifySurfaceV1(args: String) -> String { notifySurface(args) }

    func controlNotifyTargetV1(args: String) -> String { notifyTarget(args) }

    func controlNotifyTargetQueuedV1(args: String) -> String { notifyTargetQueued(args) }

    func controlNotificationsListV1() -> String { listNotifications() }

    func controlNotificationsClearV1(args: String) -> String { clearNotifications(args) }

    func controlHelpTextV1() -> String { helpText() }
}

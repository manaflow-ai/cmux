import AppKit
import CmuxNextDesign
import CmuxNextActions
import CmuxNextSettings
import CmuxNextSettingsWindow

/// Window and app-level actions (category `window`) not bound in
/// `AppActions`: settings, show/hide, About, Keep Mac Awake, palette
/// navigation. Features cmux-next has not built yet report a typed
/// `ActionFailure` so the CLI and palette say so.
enum WindowHandlers {
    /// Held while "Keep Mac Awake" is on.
    private final class KeepAwake { var activity: (any NSObjectProtocol)? }

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let keepAwake = KeepAwake()
        registry.bind("openSettings", run: { invocation in
            let link = SettingsDeepLink(invocation)
            try context.services.settingsWindow.show(section: link.section, setting: link.setting)
        })
        // DEV and NIGHTLY only: the descriptor is `isDebugOnly` (`DevTools`).
        registry.bind("openDebugSettings", run: { _ in try context.services.debugSettings.show() })
        registry.bind("about", run: { _ in
            context.activateApp()
            NSApp.orderFrontStandardAboutPanel(nil)
        })
        registry.bind("showMainWindow", run: { _ in showMainWindow(context) })
        registry.bind("showHideAllWindows", run: { _ in
            if NSApp.isActive, !NSApp.isHidden, context.services.windows.controllers.contains(where: { $0.window?.isVisible == true }) {
                NSApp.hide(nil)
            } else {
                NSApp.unhide(nil)
                showMainWindow(context)
            }
        })
        registry.bind("minimizeWindow", run: { _ in
            // Show Main Window (showMainWindow) restores it.
            context.activeWindow?.window?.miniaturize(nil)
        })
        registry.bind("keepMacAwake", run: { _ in toggleKeepAwake(keepAwake) })
        registry.bind("commandPaletteNext", run: { _ in context.services.palette.model.handle(.moveDown) })
        registry.bind("commandPalettePrevious", run: { _ in context.services.palette.model.handle(.moveUp) })

        let unbuilt: [(ActionID, String)] = [
            ("palette.openTaskManager", "task-manager"),
            ("taskManager.killProcess", "task-manager"),
            ("palette.sleepyMode", "sleepy-mode"),
        ]
        for (id, feature) in unbuilt {
            registry.bindUnavailable([id], ActionFailure.needsAppCapability(feature))
        }
    }

    private static func showMainWindow(_ context: AppActionContext) {
        guard let window = context.activeWindow?.window else {
            context.services.windows.reopenOrCreateWindow()
            return
        }
        WindowActivation.show(window, .focus)
    }

    /// Prevents idle system sleep while on; a second run turns it off.
    private static func toggleKeepAwake(_ state: KeepAwake) {
        if let activity = state.activity {
            ProcessInfo.processInfo.endActivity(activity)
            state.activity = nil
        } else {
            state.activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "cmux Keep Mac Awake"
            )
        }
    }
}

import AppKit
import CmuxNextDesign
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextPalette
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
        // Settings and Debug Settings open as internal page tabs.
        context.services.pages.register(context.services.settingsWindow)
        context.services.pages.register(context.services.debugSettings)
        registry.bind("openSettings", run: { invocation in
            let link = SettingsDeepLink(invocation)
            try context.services.settingsWindow.show(section: link.section, setting: link.setting, focus: invocation.allowsViewChange)
        })
        // DEV and NIGHTLY only: the descriptor is `isDebugOnly` (`DevTools`).
        registry.bind("openDebugSettings", run: { invocation in try context.services.debugSettings.show(focus: invocation.allowsViewChange) })
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
        registry.bind("closeAllWindows", run: { _ in
            // Each window's own close path (its confirmation included).
            for controller in context.services.windows.controllers { controller.window?.performClose(nil) }
        })
        registry.bind("zoomWindow", run: { _ in context.activeWindow?.window?.zoom(nil) })
        registry.bind("selectNextWindow", run: { _ in selectWindow(offset: 1, context) })
        registry.bind("selectPreviousWindow", run: { _ in selectWindow(offset: -1, context) })
        registry.bind("keepMacAwake", run: { _ in toggleKeepAwake(keepAwake) })
        registry.bind("commandPaletteNext", run: { _ in context.services.palette.model.handle(.moveDown) })
        // The palette's own keys as actions (PaletteKeyActionCatalog): the open palette runs the command.
        for id in PaletteKeyMap.paletteKeyActions {
            guard let command = PaletteKeyMap.command(forAction: id) else { continue }
            registry.bind(id, run: { _ in context.services.palette.model.handle(command) })
        }
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

    /// The visible cmux window `offset` places after the active one, wrapping.
    private static func selectWindow(offset: Int, _ context: AppActionContext) {
        let windows = context.services.windows.controllers.compactMap(\.window).filter(\.isVisible)
        guard windows.count > 1 else { return }
        let current = context.activeWindow?.window.flatMap { active in windows.firstIndex { $0 === active } } ?? 0
        WindowActivation.show(windows[(current + offset + windows.count) % windows.count], .focus)
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

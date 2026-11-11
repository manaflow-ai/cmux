import AppKit
import CmuxNextDesign
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextKeepAwake
import CmuxNextPalette
import CmuxNextSettings
import CmuxNextSettingsWindow

/// Window and app-level actions (category `window`) not bound in
/// `AppActions`: settings, show/hide, About, Keep Mac Awake, palette
/// navigation.
enum WindowHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        // Settings and Debug Settings open as internal page tabs.
        context.services.pages.register(context.services.settingsWindow)
        context.services.pages.register(context.services.debugSettings)
        registry.bind("openSettings", run: { invocation in
            let link = SettingsDeepLink(invocation)
            try context.services.settingsWindow.show(section: link.section, setting: link.setting, focus: invocation.allowsViewChange)
        })
        // DEV and NIGHTLY only: the descriptor is `isDebugOnly` (`DevTools`).
        registry.bind("openDebugSettings", run: { invocation in try context.services.debugSettings.show(focus: invocation.allowsViewChange) })
        DebugTunableSwitchActions(show: "hostPressure.showWarning", hide: "hostPressure.hideWarning", tunable: HostPressureTunables.enabled).bind(into: registry)
        // DEV and NIGHTLY (`isDebugOnly`): the per-action budget's HUD; it never takes the keys.
        registry.bindEffect("debug.actionLatencyHUD", effect: { _ in
            context.services.actionLatencyHUD.toggle(over: context.services.windows.active?.window)
            return .done
        })
        ActionTargetTitles.setPaletteState("debug.actionLatencyHUD", in: registry) { context.services.actionLatencyHUD.isShown }
        // DEV and NIGHTLY (`isDebugOnly`): Main-Thread Blocking's counts reset and its call sites copied. Enabled
        // only in a build that has the detector (Debug, `CMUX_BLOCKING_CHECKS`): elsewhere they do nothing.
        let blocking = context.services.blocking
        registry.bindEffect("debug.blockingCalls.reset", isEnabled: { blocking.isCompiledIn }, effect: { _ in
            blocking.resetCounts()
            return .done
        })
        registry.bindEffect("debug.blockingCalls.copy", isEnabled: { blocking.isCompiledIn }, effect: { [weak registry] _ in
            // Kind, code location and count are diagnostic tokens, not prose: not localized.
            registry?.copyText(blocking.sites.map { "\($0.kind.rawValue)  \($0.location)  ×\($0.count)" }.joined(separator: "\n"))
            return .done
        })
        DebugTunableChoiceAction(id: "debug.sidebarToggleIcon", argument: "icon", suggestions: ActionSuggestions.debugSidebarToggleIcons,
                                 tunable: SidebarToggleIcon.tunable).bind(into: registry)
        DebugTunableChoiceAction(id: "debug.statusIconSet", argument: "set", suggestions: ActionSuggestions.debugStatusIconSets,
                                 tunable: StatusIconSet.tunable).bind(into: registry)
        // Debug-only actions reach the person only while Internal Developer Mode is on, read at each palette
        // open and key press (no restart); scripts reach them wherever developer tools exist.
        registry.debugActions = DebugActionGate(isOn: { [weak services = context.services] in
            services?.settings.map { InternalDeveloperModeSetting().value(in: $0.snapshot.root) } ?? false
        })
        registry.bind("about", run: { _ in
            context.activateApp()
            let credits = AboutPanelCredits(bundle: .main).credits
            NSApp.orderFrontStandardAboutPanel(options: credits.map { [.credits: $0] } ?? [:])
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
        registry.bind("minimizeWindow", run: { invocation in
            // The window the target names (an agent's `window:<id>`), else the active one; Show Main Window restores it.
            try context.window(invocation).window?.miniaturize(nil)
        })
        registry.bind("closeAllWindows", run: { _ in
            // Each window's own close check (an incognito window asks), then close.
            for window in context.services.windows.controllers.compactMap(\.window) { WindowTargeting.close(window) }
        })
        registry.bind("zoomWindow", run: { _ in targeting(context).target?.zoom(nil) })
        registry.bind("selectNextWindow", run: { _ in selectWindow(offset: 1, context) })
        registry.bind("selectPreviousWindow", run: { _ in selectWindow(offset: -1, context) })
        registry.bind("keepMacAwake", run: { _ in KeepAwakeService.shared.toggleManual() })
        // Sleepy Mode: palette, Window menu, `cmux app sleepy-mode` and MCP all toggle the one controller.
        registry.bind("palette.sleepyMode", run: { _ in context.services.sleepyMode.toggle() })
        registry.bind("commandPaletteNext", run: { _ in context.services.palette.model.handle(.moveDown) })
        // The palette's own keys as actions (PaletteKeyActionCatalog): the open palette runs the command.
        for id in PaletteKeyMap.paletteKeyActions {
            guard let command = PaletteKeyMap.command(forAction: id) else { continue }
            registry.bind(id, run: { _ in context.services.palette.model.handle(command) })
        }
        registry.bind("commandPalettePrevious", run: { _ in context.services.palette.model.handle(.moveUp) })
    }

    private static func showMainWindow(_ context: AppActionContext) {
        guard let window = context.activeWindow?.window else {
            context.services.windows.reopenOrCreateWindow()
            return
        }
        WindowActivation.show(window, .focus)
    }

    private static func targeting(_ context: AppActionContext) -> WindowTargeting {
        WindowTargeting.current(context.services.windows.controllers.compactMap(\.window).filter(\.isVisible))
    }

    /// The cmux window `offset` places from the key or frontmost one, wrapping.
    private static func selectWindow(offset: Int, _ context: AppActionContext) {
        guard let window = targeting(context).cycled(offset) else { return }
        WindowActivation.show(window, .focus)
    }
}

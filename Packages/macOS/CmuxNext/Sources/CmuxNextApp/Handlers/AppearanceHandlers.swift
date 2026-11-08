import CmuxNextActions
import CoreGraphics
import CmuxNextDesign
import CmuxNextSettings

/// Animation speed, titlebar style, interface size (the chrome body
/// font; terminal fonts come from the Ghostty config) and pane chrome
/// (border, padding: `PaneChromeToggles`). Applied to `DesignSettings` at once, then
/// written to cmux.json through the validated `setSetting` path
/// (`AppActionContext.writeSetting`), which owns settings; the watcher
/// reapplies the same value. Tests pass their own `tunables` (Debug choices).
enum AppearanceHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext, tunables: TunableStore = .shared) {
        let uiScale = UIScaleSetting()
        // Customize Appearance… opens Settings on Appearance (R82: the studio panel went with the Swift Settings UI).
        registry.bind("appearance.customize", run: { invocation in
            try context.services.settingsWindow.show(section: .appearance, focus: invocation.allowsViewChange)
        })
        // Change Background… (the window's or a chat's empty-space menu) opens Settings on the art
        // picker, which can also set the clicked (else the shown) workspace's own background.
        registry.bind("appearance.changeBackground", run: { invocation in
            let settings = context.services.settingsWindow
            let workspace = context.scope(invocation).workspace?.id
            do {
                try settings.show(section: .appearance, setting: "appearance.background", focus: invocation.allowsViewChange,
                                  route: SettingsWindowService.backgroundRoute(workspace: workspace))
            } catch {
                try settings.show(section: .appearance, focus: invocation.allowsViewChange)
            }
        })
        let save: SettingChoiceActions.Save = { path, value in
            if let managed = context.services.settings?.managedKey(forPath: path) { return RefusalStrings.settingManaged(managed.key) }
            context.writeSetting("set \(path.joined(separator: "."))", path, value, reloadOnFailure: true)
            return nil
        }
        SettingChoiceActions.bind(MotionSpeed.allCases, into: registry, id: { "appearance.animationSpeed.\($0.rawValue)" }, path: AnimationSpeedSetting.configPath,
                                  fileValue: { .string($0.rawValue) }, save: save) { context.design.animationSpeed = $0 }
        AnimationKindsSetting.bindActions(into: registry, design: context.design, save: save)
        MotionCategoriesSetting.bindActions(into: registry, design: context.design, save: save)
        SettingChoiceActions.bind(CenterFocusedColumn.allCases, into: registry, id: { "layout.centerFocusedColumn.\($0 == .onOverflow ? "onOverflow" : $0.rawValue)" },
                                  path: CenterFocusedColumnSetting.configPath, fileValue: { .string($0.rawValue) }, save: save) { context.design.centerFocusedColumn = $0 }
        ChromeStyleSetting.bindActions(into: registry, design: context.design, save: save)
        TabOverflowSetting.bindActions(into: registry, design: context.design, save: save)
        LinkRouting.bindActions(into: registry, save: save)
        registry.bind("appearance.interfaceSize.increase", run: { _ in try stepInterfaceSize(by: 1, context) })
        registry.bind("appearance.interfaceSize.decrease", run: { _ in try stepInterfaceSize(by: -1, context) })
        registry.bind("appearance.uiScale.increase", run: { _ in try stepUIScale(by: uiScale.step, context) })
        registry.bind("appearance.uiScale.decrease", run: { _ in try stepUIScale(by: -uiScale.step, context) })
        registry.bind("appearance.uiScale.reset", run: { _ in try resetUIScale(context) })
        PaneChromeToggles(design: context.design, save: save).bind(into: registry)
        registry.bind("appearance.paneBorderColor.reset", run: { _ in
            try requireUnmanaged(["layout", "paneBorderColor"], context)
            let design = context.design
            var chrome = design.paneChrome
            chrome.borderColor = nil
            design.setPaneChrome(chrome)
            context.writeSetting("reset pane border color", ["layout", "paneBorderColor"], nil, reloadOnFailure: true)
        })
        for style in TitlebarStyle.allCases {
            registry.bind(ActionID(rawValue: "appearance.titlebar.\(style.rawValue)"), run: { _ in try setTitlebar(style, context) })
        }
        registry.bind("appearance.glass.lens.toggle", run: { _ in GlassLensMode.choose(GlassLensMode.tunable.value(in: tunables).lensToggled, in: tunables) })
        // On while the Debug choice refracts (Lens or Spectrum): the toggle turns either back to Plain Glass.
        ActionTargetTitles.setPaletteSettingState("appearance.glass.lens.toggle", in: registry) { GlassLensMode.tunable.value(in: tunables) != .plain }
        registry.bind("appearance.interfaceSize.reset", run: { _ in
            let path = context.design.interfaceSizePath; try requireUnmanaged(path, context); context.design.resetInterfaceSize()
            context.writeSetting("reset interface size", path, nil, reloadOnFailure: true)
        })
    }

    private static let uiScalePath = UIScaleSetting.configPath

    /// `window.titlebar`: applied at once, then written to cmux.json.
    private static func setTitlebar(_ style: TitlebarStyle, _ context: AppActionContext) throws {
        try requireUnmanaged(WindowTitlebarSetting.configPath, context)
        context.design.titlebar = style
        // The default removes the key (and an emptied `window` object).
        let value: JSONValue? = style == WindowTitlebarSetting.fallback ? nil : .string(style.rawValue)
        context.writeSetting("set titlebar", WindowTitlebarSetting.configPath, value, reloadOnFailure: true)
    }

    private static func stepInterfaceSize(by delta: Double, _ context: AppActionContext) throws {
        let path = context.design.interfaceSizePath
        try requireUnmanaged(path, context)
        let value = context.design.stepInterfaceSize(by: Int(delta))
        context.writeSetting("set interface size", path, .number(value), reloadOnFailure: true)
    }

    private static func stepUIScale(by delta: Double, _ context: AppActionContext) throws {
        try requireUnmanaged(uiScalePath, context)
        let design = context.design
        let next = DesignSettings.clampedUIScale(design.uiScale + CGFloat(delta))
        design.uiScale = next
        context.writeSetting("set interface scale", uiScalePath, .number(Double(next)), reloadOnFailure: true)
    }

    private static func resetUIScale(_ context: AppActionContext) throws {
        try requireUnmanaged(uiScalePath, context)
        context.design.uiScale = CGFloat(UIScaleSetting.fallback)
        context.writeSetting("reset interface scale", uiScalePath, nil, reloadOnFailure: true)
    }

    /// Refuses before anything is applied when an MDM profile or the team
    /// policy manages the key (the file write would be refused too, but the
    /// live value would already have changed for the session).
    static func requireUnmanaged(_ path: [String], _ context: AppActionContext) throws {
        if let managed = context.services.settings?.managedKey(forPath: path) {
            throw ActionFailure.invalidTarget(RefusalStrings.settingManaged(managed.key))
        }
    }
}

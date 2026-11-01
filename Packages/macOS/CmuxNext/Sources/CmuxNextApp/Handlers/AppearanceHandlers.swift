import CmuxNextActions
import CoreGraphics
import CmuxNextDesign
import CmuxNextSettings

/// Animation speed, titlebar style, interface size (the chrome body
/// font; terminal fonts come from the Ghostty config) and pane chrome
/// (border, padding). Applied to `DesignSettings` at once, then
/// written to cmux.json through the validated `setSetting` path
/// (`AppActionContext.writeSetting`), which owns settings; the watcher
/// reapplies the same value.
enum AppearanceHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
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
        registry.bind("appearance.paneBorder.toggle", run: { _ in try togglePaneBorder(context) })
        registry.bind("appearance.panePadding.toggle", run: { _ in try togglePanePadding(context) })
        registry.bind("appearance.paneCorners.toggle", run: { _ in try togglePaneCorners(context) })
        registry.bind("appearance.paneBorderWidth.toggle", run: { _ in try togglePaneBorderWidth(context) })
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
        registry.bind("appearance.glass.lens.toggle", run: { _ in GlassLensMode.choose(GlassLensMode.tunable.value.lensToggled) })
        registry.bind("appearance.interfaceSize.reset", run: { _ in
            let path = context.design.interfaceSizePath; try requireUnmanaged(path, context); context.design.resetInterfaceSize()
            context.writeSetting("reset interface size", path, nil, reloadOnFailure: true)
        })
    }

    private static let uiScalePath = UIScaleSetting().configPath

    /// Subtle border on or off. Subtle is the default, so turning it back
    /// on removes the key instead of writing it.
    private static func togglePaneBorder(_ context: AppActionContext) throws {
        try requireUnmanaged(["layout", "paneBorder"], context)
        let design = context.design
        // The configured border, not the drawn one (appearance.borders none draws none).
        let next: PaneBorderStyle = (design.paneChrome.border ?? .subtle) == .subtle ? .none : .subtle
        var chrome = design.paneChrome
        chrome.border = next == .subtle ? nil : next
        design.setPaneChrome(chrome)
        let border = chrome.border.map { JSONValue.string($0.rawValue) }
        context.writeSetting("toggle pane border", ["layout", "paneBorder"], border, reloadOnFailure: true)
    }

    /// Padding off (0) or back to the density default.
    private static func togglePanePadding(_ context: AppActionContext) throws {
        try requireUnmanaged(["layout", "panePadding"], context)
        let design = context.design
        var chrome = design.paneChrome
        chrome.padding = Metrics.panePadding > 0 ? 0 : nil
        design.setPaneChrome(chrome)
        let padding = chrome.padding.map { JSONValue.number(Double($0)) }
        context.writeSetting("toggle pane padding", ["layout", "panePadding"], padding, reloadOnFailure: true)
    }

    /// Square corners (0) or back to the default radius. With no padding and
    /// no border the default is square, so "rounded" writes the density
    /// radius explicitly.
    private static func togglePaneCorners(_ context: AppActionContext) throws {
        try requireUnmanaged(["layout", "paneCornerRadius"], context)
        let design = context.design
        var chrome = design.paneChrome
        if Metrics.paneCornerRadius > 0 {
            chrome.cornerRadius = 0
        } else {
            chrome.cornerRadius = nil
            design.setPaneChrome(chrome)
            if Metrics.paneCornerRadius == 0 { chrome.cornerRadius = Metrics.densityPaneCornerRadius }
        }
        design.setPaneChrome(chrome)
        let radius = chrome.cornerRadius.map { JSONValue.number(Double($0)) }
        context.writeSetting("toggle pane corners", ["layout", "paneCornerRadius"], radius, reloadOnFailure: true)
    }

    /// Border width: one device pixel (the default, key removed) or 2 pt.
    private static func togglePaneBorderWidth(_ context: AppActionContext) throws {
        try requireUnmanaged(["layout", "paneBorderWidth"], context)
        let design = context.design
        var chrome = design.paneChrome
        chrome.borderWidth = Metrics.paneBorderWidth == nil ? 2 : nil
        design.setPaneChrome(chrome)
        let width = chrome.borderWidth.map { JSONValue.number(Double($0)) }
        context.writeSetting("toggle pane border width", ["layout", "paneBorderWidth"], width, reloadOnFailure: true)
    }

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
        context.design.uiScale = CGFloat(UIScaleSetting().fallback)
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

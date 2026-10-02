import CmuxNextActions
import CoreGraphics
import CmuxNextDesign
import CmuxNextSettings

/// Density, animation speed, titlebar style, interface size (the chrome body
/// font; terminal fonts come from the Ghostty config) and pane chrome
/// (border, padding). Applied to `DesignSettings` at once, then
/// written to cmux.json through the validated `setSetting` path
/// (`AppActionContext.writeSetting`), which owns settings; the watcher
/// reapplies the same value.
enum AppearanceHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let studio = AppearanceStudioController(context: context)
        registry.bind("appearance.customize", run: { _ in try studio.toggle() })
        registry.bind("appearance.density.compact", run: { _ in try setDensity(.compact, context) })
        registry.bind("appearance.density.comfortable", run: { _ in try setDensity(.comfortable, context) })
        for speed in MotionSpeed.allCases {
            registry.bind(ActionID(rawValue: "appearance.animationSpeed.\(speed.rawValue)"), run: { _ in try setAnimationSpeed(speed, context) })
        }
        for mode in CenterFocusedColumn.allCases {
            let id = mode == .onOverflow ? "onOverflow" : mode.rawValue
            registry.bind(ActionID(rawValue: "layout.centerFocusedColumn.\(id)"), run: { _ in try setCenterFocusedColumn(mode, context) })
        }
        registry.bind("appearance.interfaceSize.increase", run: { _ in try stepInterfaceSize(by: 1, context) })
        registry.bind("appearance.interfaceSize.decrease", run: { _ in try stepInterfaceSize(by: -1, context) })
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
        registry.bind("appearance.interfaceSize.reset", run: { _ in
            try requireUnmanaged(fontSizePath, context)
            context.design.setOverride(.chromeFontSize, nil)
            context.writeSetting("reset interface size", fontSizePath, nil, reloadOnFailure: true)
        })
    }

    private static let fontSizePath = InterfaceSizeSetting().configPath

    private static func setDensity(_ density: Density, _ context: AppActionContext) throws {
        try requireUnmanaged(["appearance", "density"], context)
        context.design.density = density
        context.writeSetting("set density", ["appearance", "density"], .string(density.rawValue), reloadOnFailure: true)
    }

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

    /// `ui.animationSpeed`: applied at once, then written to cmux.json.
    private static func setAnimationSpeed(_ speed: MotionSpeed, _ context: AppActionContext) throws {
        try requireUnmanaged(AnimationSpeedSetting.configPath, context)
        context.design.animationSpeed = speed
        context.writeSetting("set animation speed", AnimationSpeedSetting.configPath, .string(speed.rawValue), reloadOnFailure: true)
    }

    /// `layout.centerFocusedColumn`: applied at once, then written to cmux.json.
    private static func setCenterFocusedColumn(_ mode: CenterFocusedColumn, _ context: AppActionContext) throws {
        try requireUnmanaged(CenterFocusedColumnSetting.configPath, context)
        context.design.centerFocusedColumn = mode
        context.writeSetting("set center focused column", CenterFocusedColumnSetting.configPath, .string(mode.rawValue), reloadOnFailure: true)
    }

    /// Body size in points: the override, else the density default.
    static func interfaceSize(_ design: DesignSettings = .shared) -> Double {
        Double(design.overrides[.chromeFontSize] ?? (design.density == .compact ? 12 : 13))
    }

    private static func stepInterfaceSize(by delta: Double, _ context: AppActionContext) throws {
        try requireUnmanaged(fontSizePath, context)
        let design = context.design
        design.setOverride(.chromeFontSize, CGFloat(interfaceSize(design) + delta))
        let size = interfaceSize(design)
        context.writeSetting("set interface size", fontSizePath, .number(size), reloadOnFailure: true)
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

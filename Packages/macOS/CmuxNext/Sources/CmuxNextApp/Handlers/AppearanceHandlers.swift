import CmuxNextActions
import CoreGraphics
import CmuxNextDesign
import CmuxNextSettings
import os

/// Density, animation speed, titlebar style, interface size (the chrome body
/// font; terminal fonts come from the Ghostty config) and pane chrome
/// (border, padding). Applied to `DesignSettings` at once, then
/// written to cmux.json, which owns settings; the watcher reapplies the
/// same value.
enum AppearanceHandlers {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.actions")

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("appearance.density.compact", run: { _ in setDensity(.compact, context) })
        registry.bind("appearance.density.comfortable", run: { _ in setDensity(.comfortable, context) })
        for speed in MotionSpeed.allCases {
            registry.bind(ActionID(rawValue: "appearance.animationSpeed.\(speed.rawValue)"), run: { _ in setAnimationSpeed(speed, context) })
        }
        for mode in CenterFocusedColumn.allCases {
            let id = mode == .onOverflow ? "onOverflow" : mode.rawValue
            registry.bind(ActionID(rawValue: "layout.centerFocusedColumn.\(id)"), run: { _ in setCenterFocusedColumn(mode, context) })
        }
        registry.bind("appearance.interfaceSize.increase", run: { _ in stepInterfaceSize(by: 1, context) })
        registry.bind("appearance.interfaceSize.decrease", run: { _ in stepInterfaceSize(by: -1, context) })
        registry.bind("appearance.paneBorder.toggle", run: { _ in togglePaneBorder(context) })
        registry.bind("appearance.panePadding.toggle", run: { _ in togglePanePadding(context) })
        registry.bind("appearance.paneCorners.toggle", run: { _ in togglePaneCorners(context) })
        registry.bind("appearance.paneBorderWidth.toggle", run: { _ in togglePaneBorderWidth(context) })
        registry.bind("appearance.paneBorderColor.reset", run: { _ in
            let design = DesignSettings.shared
            var chrome = design.paneChrome
            chrome.borderColor = nil
            design.setPaneChrome(chrome)
            write(context, "reset pane border color") { try await $0.setPaneBorderColor(nil) }
        })
        for style in TitlebarStyle.allCases {
            registry.bind(ActionID(rawValue: "appearance.titlebar.\(style.rawValue)"), run: { _ in setTitlebar(style, context) })
        }
        registry.bind("appearance.interfaceSize.reset", run: { _ in
            DesignSettings.shared.setOverride(.chromeFontSize, nil)
            write(context, "reset interface size") { try await $0.file.remove(fontSizePath) }
        })
    }

    private static let fontSizePath = ["appearance", "metrics", MetricKey.chromeFontSize.rawValue]

    private static func setDensity(_ density: Density, _ context: AppActionContext) {
        DesignSettings.shared.density = density
        write(context, "set density") { try await $0.setDensity(density) }
    }

    /// Subtle border on or off. Subtle is the default, so turning it back
    /// on removes the key instead of writing it.
    private static func togglePaneBorder(_ context: AppActionContext) {
        let design = DesignSettings.shared
        let next: PaneBorderStyle = Metrics.paneBorder == .subtle ? .none : .subtle
        var chrome = design.paneChrome
        chrome.border = next == .subtle ? nil : next
        design.setPaneChrome(chrome)
        let border = chrome.border
        write(context, "toggle pane border") { try await $0.setPaneBorder(border) }
    }

    /// Padding off (0) or back to the density default.
    private static func togglePanePadding(_ context: AppActionContext) {
        let design = DesignSettings.shared
        var chrome = design.paneChrome
        chrome.padding = Metrics.panePadding > 0 ? 0 : nil
        design.setPaneChrome(chrome)
        let padding = chrome.padding.map(Double.init)
        write(context, "toggle pane padding") { try await $0.setPanePadding(padding) }
    }

    /// Square corners (0) or back to the default radius. With no padding and
    /// no border the default is square, so "rounded" writes the density
    /// radius explicitly.
    private static func togglePaneCorners(_ context: AppActionContext) {
        let design = DesignSettings.shared
        var chrome = design.paneChrome
        if Metrics.paneCornerRadius > 0 {
            chrome.cornerRadius = 0
        } else {
            chrome.cornerRadius = nil
            design.setPaneChrome(chrome)
            if Metrics.paneCornerRadius == 0 { chrome.cornerRadius = Metrics.densityPaneCornerRadius }
        }
        design.setPaneChrome(chrome)
        let radius = chrome.cornerRadius.map(Double.init)
        write(context, "toggle pane corners") { try await $0.setPaneCornerRadius(radius) }
    }

    /// Border width: one device pixel (the default, key removed) or 2 pt.
    private static func togglePaneBorderWidth(_ context: AppActionContext) {
        let design = DesignSettings.shared
        var chrome = design.paneChrome
        chrome.borderWidth = Metrics.paneBorderWidth == nil ? 2 : nil
        design.setPaneChrome(chrome)
        let width = chrome.borderWidth.map(Double.init)
        write(context, "toggle pane border width") { try await $0.setPaneBorderWidth(width) }
    }

    /// `window.titlebar`: applied at once, then written to cmux.json.
    private static func setTitlebar(_ style: TitlebarStyle, _ context: AppActionContext) {
        DesignSettings.shared.titlebar = style
        write(context, "set titlebar") { try await $0.setTitlebar(style) }
    }

    /// `ui.animationSpeed`: applied at once, then written to cmux.json.
    private static func setAnimationSpeed(_ speed: MotionSpeed, _ context: AppActionContext) {
        DesignSettings.shared.animationSpeed = speed
        write(context, "set animation speed") { try await $0.setAnimationSpeed(speed) }
    }

    /// `layout.centerFocusedColumn`: applied at once, then written to cmux.json.
    private static func setCenterFocusedColumn(_ mode: CenterFocusedColumn, _ context: AppActionContext) {
        DesignSettings.shared.centerFocusedColumn = mode
        write(context, "set center focused column") {
            try await $0.set(.string(mode.rawValue), at: CenterFocusedColumnSetting.configPath)
        }
    }

    /// Body size in points: the override, else the density default.
    static func interfaceSize(_ design: DesignSettings = .shared) -> Double {
        Double(design.overrides[.chromeFontSize] ?? (design.density == .compact ? 12 : 13))
    }

    private static func stepInterfaceSize(by delta: Double, _ context: AppActionContext) {
        let design = DesignSettings.shared
        design.setOverride(.chromeFontSize, CGFloat(interfaceSize(design) + delta))
        let size = interfaceSize(design)
        write(context, "set interface size") { try await $0.set(.number(size), at: fontSizePath) }
    }

    private static func write(_ context: AppActionContext, _ label: String,
                              _ body: @escaping @Sendable (SettingsController) async throws -> Void) {
        guard let settings = context.services.settings else { return }
        Task {
            do { try await body(settings) } catch {
                logger.error("\(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

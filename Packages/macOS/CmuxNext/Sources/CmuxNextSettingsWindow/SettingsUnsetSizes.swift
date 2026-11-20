public import CoreGraphics
import CmuxNextDesign
public import CmuxNextSettings

/// What every unset size row draws now, in the points cmux.json stores, so the Settings row shows a
/// real number instead of its default's name ("Density default", "Ghostty", "One pixel"; standup
/// 2026-11-11): the density's sizes (the `Metrics` values without the Debug-only interface scale
/// multiplier), Text Size, the tab titles' size, the terminal's font size and a one-pixel border.
/// The host passes in what only the app knows.
@MainActor
public struct SettingsUnsetSizes {
    /// The terminal's font size (the Ghostty config's, or terminal.fontSize); the editor follows it.
    public var terminalFontSize: Double?
    /// The active window's display scale, for a one-device-pixel border.
    public var backingScale: CGFloat

    public init(terminalFontSize: Double?, backingScale: CGFloat) {
        self.terminalFontSize = terminalFontSize
        self.backingScale = backingScale
    }

    /// The page's live values of unset number rows, by schema key: the window opacity the theme
    /// resolved (when known), then every size row.
    public func derivedNumbers(windowOpacity: Double?) -> [String: JSONValue] {
        var derived: [String: JSONValue] = [:]
        let opacity: [([String], Double)] = windowOpacity.map { [(WindowBackgroundSetting.opacityPath, $0)] } ?? []
        for (path, value) in opacity + sizes() {
            guard let id = SettingsSchema.descriptor(for: path)?.id else { continue }
            derived[id] = .number(value)
        }
        return derived
    }

    /// Each size row's config path and its value now.
    public func sizes() -> [([String], Double)] {
        let design = DesignSettings.shared
        let scale = design.interfaceScaleEnabled ? design.interfaceScale : 1
        let points = { (value: CGFloat) in Double((value / max(scale, 0.01) * 2).rounded() / 2) }
        let metrics: [(LayoutMetricSetting, CGFloat)] = [
            (.sidebarWidth, Metrics.sidebarWidth), (.columnGap, Metrics.columnGap),
            (.dividerThickness, Metrics.dividerThickness), (.dividerHitWidth, Metrics.dividerHitWidth),
            (.titlebarHeight, Metrics.titlebarHeight), (.tabStripHeight, Metrics.tabStripHeight),
            (.tabMaxWidth, Metrics.tabMaxWidth), (.tabMinActiveWidth, Metrics.tabMinActiveWidth),
            (.tabMinInactiveWidth, Metrics.tabMinInactiveWidth), (.tabPinnedWidth, Metrics.tabPinnedWidth),
        ]
        var sizes = metrics.map { ($0.0.configPath, points($0.1)) }
        // Text Size: the density's body size (the tokens carry no scale).
        sizes.append((InterfaceSizeSetting.configPath, Double(design.overrides[.chromeFontSize] ?? Metrics.tokens.bodySize)))
        sizes.append((["layout", "panePadding"], points(Metrics.panePadding)))
        sizes.append((["layout", "paneCornerRadius"], points(Metrics.paneCornerRadius)))
        sizes.append((["layout", "cornerPadding"], points(Metrics.cornerPadding)))
        // Tab titles follow the interface size: Chrome's 12 pt times the text scale (`Typography.tabTitle`).
        sizes.append((LayoutMetricSetting.tabFontSize.configPath, points(12 * Typography.userScale)))
        if let terminalFontSize {
            sizes.append((["terminal", "fontSize"], terminalFontSize))
            sizes.append((["editor", "fontSize"], terminalFontSize))
        }
        let pixel = Double(1 / max(backingScale, 1))
        sizes.append((["layout", "paneBorderWidth"], pixel))
        sizes.append((["sidebar", "borderWidth"], pixel))
        return sizes
    }
}

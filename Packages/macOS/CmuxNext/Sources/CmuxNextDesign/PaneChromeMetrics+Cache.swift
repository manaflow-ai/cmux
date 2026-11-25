public import AppKit
import CmuxNextDesignTokens

/// ``PaneChromeMetrics/current``'s derivation, cached on its inputs. During a live window resize the pane chrome read it
/// about a thousand times a second: the other Mac's samples (2026-11-24, in-tree OFF) put `PaneChromeMetrics.current` at
/// about 21% of `ShellWindow.setFrame`, read from the tab strip's inset, the top row's line, each pane's strip height and
/// the corner chrome, each read rebuilding the strip, the tab and the padding from settings, tunables and density tokens.
///
/// Every read still touches every observable input (``Inputs/read()``): a view that reads the metrics in `layout()`
/// keeps its Observation dependency on each, so a density, override or tunable change still lays it out again. Only
/// the arithmetic after those reads is skipped when the inputs are the ones the cached value was made from.
extension PaneChromeMetrics {
    /// The values ``current`` is derived from: every `DesignSettings` property the metrics behind it read (Metrics,
    /// CornerFlush, MainPane, TabCornerRadius, Borders, the sidebar row tokens), every tunable override, the active
    /// density (a preview's scoped one too) and the system's contrast setting. Equal inputs give an equal ``current``
    /// (``PaneChromeMetricsCacheTests`` checks the cached value against a fresh derivation after each kind of change).
    struct Inputs: Equatable {
        var density: DensityTokens
        var designOverrides: [MetricKey: CGFloat]
        var paneChrome: PaneChromeOverrides
        var sidebarSections: SidebarSectionsPreferences
        var chromeStyle: ChromeStyle
        var borders: BorderMode
        var interfaceScale: CGFloat
        var verticalTabs: Bool
        var tabBarPosition: TabBarPosition
        var tabBarOrder: TabBarOrder
        var sidebarBorder: SidebarBorder
        var sidebarSurface: SidebarSurface
        var titleAreaContrast: CGFloat
        var titleAreaTone: TitleAreaTone
        var titlebar: TitlebarStyle
        var tunables: [String: TunableValue]
        var increaseContrast: Bool

        /// Reads every input, each through its observable accessor (one Observation dependency per input).
        @MainActor static func read() -> Inputs {
            let settings = DesignSettings.shared
            return Inputs(density: DensityTokens.active, designOverrides: settings.overrides, paneChrome: settings.paneChrome,
                          sidebarSections: settings.sidebarSections, chromeStyle: settings.chromeStyle, borders: settings.borders,
                          interfaceScale: settings.interfaceScale, verticalTabs: settings.verticalTabs,
                          tabBarPosition: settings.tabBarPosition, tabBarOrder: settings.tabBarOrder,
                          sidebarBorder: settings.sidebarBorder, sidebarSurface: settings.sidebarSurface,
                          titleAreaContrast: settings.titleAreaContrast, titleAreaTone: settings.titleAreaTone,
                          titlebar: settings.titlebar, tunables: TunableStore.shared.overrides,
                          increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        }
    }

    /// The last ``current`` and the inputs it was made from.
    @MainActor static var cached: (inputs: Inputs, metrics: PaneChromeMetrics)?
    /// Derivations ``current`` did and reads it answered from the cache (tests, `debug.layout_counters`).
    @MainActor static var derivations = 0
    @MainActor static var hits = 0

    /// ``current``: the cached value when the inputs match, else derived and kept.
    @MainActor static func cachedCurrent(derive: () -> PaneChromeMetrics) -> PaneChromeMetrics {
        let inputs = Inputs.read()
        if let cached, cached.inputs == inputs {
            hits += 1
            return cached.metrics
        }
        let metrics = derive()
        derivations += 1
        cached = (inputs, metrics)
        return metrics
    }
}

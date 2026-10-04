public import CoreGraphics
public import Observation

/// Metrics a user may override individually on top of a density preset.
/// Raw values are the cmux.json keys under `appearance.metrics`.
public enum MetricKey: String, Sendable, CaseIterable, Codable {
    case sidebarWidth
    case sidebarRowHeight
    case tabStripHeight
    case tabMaxWidth
    case paletteRowHeight
    case columnGap
    case panelCornerRadius
    case chromeFontSize
}

/// Live, user-configurable design settings. The App fills this from
/// cmux.json (`appearance.density`, `appearance.metrics.*`) and from the
/// Settings window / palette; every Metrics and Typography read goes through
/// it, so changes apply to all surfaces without relaunch.
@Observable
public final class DesignSettings {
    public static let shared = DesignSettings()

    /// Intentional Command/Control hold hints (`shortcuts.showModifierHoldHints`).
    public var showModifierHoldHints = true
    public var density: Density = .compact
    /// `ui.animationSpeed`: how fast chrome animates (see `Motion`).
    public var animationSpeed: MotionSpeed = .fast
    /// Per-metric overrides in points, clamped by `setOverride`.
    public private(set) var overrides: [MetricKey: CGFloat] = [:]
    /// Pane padding, corner radius and border from cmux.json `layout.*`,
    /// clamped by `setPaneChrome`.
    public private(set) var paneChrome = PaneChromeOverrides()
    /// `layout.centerFocusedColumn`.
    public var centerFocusedColumn: CenterFocusedColumn = .never
    /// `layout.stripScrollbar`: the column strip's scrollbar.
    public var stripScrollbar: StripScrollbarMode = .auto
    /// `sidebar.*`: section look and sticky band caps.
    public var sidebarSections = SidebarSectionsPreferences.defaults
    /// `layout.closeFocus`: who gets focus when the focused pane closes.
    public var closeFocus: CloseFocusPolicy = .previousNeighbor
    /// `layout.defaultColumnWidth`: new column width, a viewport fraction.
    public var defaultColumnWidth: Double = 0.5
    /// `layout.newColumnWidth`: how a new column's width is chosen.
    public var newColumnWidth: NewColumnWidthMode = .matchCurrent
    /// `layout.splitSizing`: what a split does to its column.
    public var splitSizing: SplitSizing = .even
    /// `layout.stickyColumnEdge`, `layout.stickyColumnMode`.
    public var stickyColumnEdge: StickyDefaultEdge = .nearest
    public var stickyColumnMode: StickyDefaultMode = .docked
    /// `layout.frameOrientation`: column-major (side docks full height) or
    /// row-major (top and bottom docks full width), plans/cmux-next/layout-model.md.
    public var frameOrientation: FrameOrientation = .columnMajor
    /// `layout.rows`: off hides every row entry point and fits existing
    /// rows into their column (plans/cmux-next/rows.md O1 to O3).
    public var layoutRows = true
    /// `layout.minimumPaneWidth`, `layout.minimumPaneHeight`: the smallest
    /// content area a pane keeps below its chrome, in points.
    public var minimumPaneContentSize = CGSize(width: 200, height: 64)
    /// `focusRing.*`: the focused pane's ring or glow.
    public var focusRing = FocusRingSettings()
    /// `notifications.attention.*`: the unread pane's attention ring.
    public var attention = AttentionSettings()
    /// `appearance.statusIndicator.*`: loading and status indicators on
    /// sidebar rows, tabs, sections and pane headers.
    public var statusIndicator = StatusIndicatorSettings()
    /// cmux's terminal font override (`terminal.fontFamily` in cmux.json),
    /// so chrome that imitates the terminal (the braille status indicator)
    /// draws in it. Nil (no override; a font set only in the Ghostty config
    /// is not read) uses the system monospaced font.
    public var terminalFontFamily: String?
    /// `status.*`: inferred command busy and run notifications.
    public var statusBehavior = StatusBehaviorSettings()
    /// `appearance.borders`: default, or none (no border, hairline or
    /// separator anywhere; `Borders`).
    public var borders: BorderMode = .default
    /// `appearance.focusIndicator`: what marks the focused pane.
    public var focusIndicator: FocusIndicator = .both
    /// `focus.inactiveTabStyle`: how an unfocused pane's tabs draw subtler
    /// when `focusIndicator` marks tabs.
    public var inactiveTabStyle: InactiveTabStyle = .fade

    /// `focusIndicator` unless Debug Settings overrides it.
    public var effectiveFocusIndicator: FocusIndicator { FocusIndicatorTunables.indicator.override ?? focusIndicator }
    /// `inactiveTabStyle` unless Debug Settings overrides it.
    public var effectiveInactiveTabStyle: InactiveTabStyle { FocusIndicatorTunables.inactiveTabStyle.override ?? inactiveTabStyle }
    /// `window.titlebar`: minimal (no titlebar strip) or standard.
    public var titlebar: TitlebarStyle = .minimal

    public init() {}

    public func setOverride(_ key: MetricKey, _ value: CGFloat?) {
        guard let value else {
            overrides[key] = nil
            return
        }
        let range = Self.allowedRange(key)
        overrides[key] = min(max(value, range.lowerBound), range.upperBound)
    }

    public func setPaneChrome(_ value: PaneChromeOverrides) {
        let clamped = value.clamped
        if paneChrome != clamped { paneChrome = clamped }
    }

    public static func allowedRange(_ key: MetricKey) -> ClosedRange<CGFloat> {
        switch key {
        case .sidebarWidth: 160...420
        case .sidebarRowHeight: 20...48
        case .tabStripHeight: 22...44
        case .tabMaxWidth: 120...320
        case .paletteRowHeight: 26...48
        case .columnGap: 0...24
        case .panelCornerRadius: 0...20
        case .chromeFontSize: 10...16
        }
    }
}

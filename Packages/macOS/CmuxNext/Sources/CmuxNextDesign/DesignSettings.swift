public import CoreGraphics
public import Observation
import Foundation
public import CmuxNextDesignTokens

/// Metrics a user may override individually on top of a density preset.
/// Raw values are the cmux.json keys under `appearance.metrics`.
public enum MetricKey: String, Sendable, CaseIterable, Codable {
    case sidebarWidth
    case sidebarRowHeight
    case tabStripHeight
    case tabMaxWidth
    /// Chrome's tab minimums (design-tokens.json `motion.tabStrip`): crowding shrinks every tab
    /// evenly to the active minimum, then the inactive tabs to theirs; pinned tabs are always one width.
    case tabMinActiveWidth
    case tabMinInactiveWidth
    case tabPinnedWidth
    case paletteRowHeight
    case columnGap
    /// The visible line and draggable hit area between split panes.
    case dividerThickness
    case dividerHitWidth
    case panelCornerRadius
    case chromeFontSize
    /// Tab titles' text size, apart from `chromeFontSize` (which sizes all chrome); unset follows it.
    case tabFontSize
    /// The unified titlebar height (cmux-browser's header height reads the same key).
    case titlebarHeight
}

/// Live, user-configurable design settings. The App fills this from
/// cmux.json (`appearance.density`, `appearance.metrics.*`) and from the
/// Settings window / palette; every Metrics and Typography read goes through
/// it, so changes apply to all surfaces without relaunch.
@Observable
public final class DesignSettings {
    public static let shared = DesignSettings()
    /// Every motion-setting change, for hosts outside Observation (``Motion/changes``).
    public let motionChanges = MotionChanges()

    /// Intentional Command/Control hold hints (`shortcuts.showModifierHoldHints`).
    public var showModifierHoldHints = true
    /// `appearance.density`: the active density's token set (plans/cmux-next/density-DESIGN.md).
    public var densityTokens: DensityTokens = .compact
    /// `appearance.customDensities`: the user's own densities, in file order.
    public var customDensities: [DensityTokens] = []
    /// Every density the user can pick: the built-ins, densest first, then the custom ones.
    public var availableDensities: [DensityTokens] { DensityPreset.allCases.map(\.tokens) + customDensities }
    /// The density with `id` among `availableDensities`.
    public func density(id: String) -> DensityTokens? { availableDensities.first { $0.id == id } }
    /// The two-way family of the active density (`DensityTokens.family`). Setting it picks that
    /// built-in (Compact or Comfortable).
    public var density: Density {
        get { densityTokens.family }
        set { densityTokens = newValue == .compact ? .compact : DensityPreset.comfortable.tokens }
    }
    /// `app.uiScale`, the content/page scale. Chrome uses `interfaceScale`.
    /// Terminal content deliberately remains owned by Ghostty's font size.
    public var uiScale: CGFloat = 1
    /// `appearance.interfaceScale`: the opt-in multiplier for the app chrome. A single token
    /// multiplier drives type, spacing and control heights across native surfaces.
    public var interfaceScale: CGFloat = 1
    /// Whether `interfaceScale` applies: the Debug Settings toggle `chrome.interfaceSize`, off by
    /// default (and always off in Release, where the tunable store is inert).
    public var interfaceScaleEnabled: Bool { ChromeTunables.interfaceSize.override ?? false }
    /// Sets the chrome multiplier and the effective page zoom used by web column sizing. The latter
    /// is passed explicitly by page hosts so Agent Chat Zoom is included without making generic pages
    /// depend on the agent setting; a change event lets chat row measurement follow CSS immediately.
    public func interfaceScaleScript(pageZoom: Double? = nil) -> String {
        let effectivePageZoom = max(pageZoom ?? Double(uiScale), 0.01)
        return "document.documentElement.style.setProperty('--cmux-interface-scale', '\(Typography.userScale)');"
            + "document.documentElement.style.setProperty('--cmux-ui-scale', '\(effectivePageZoom)');"
            + "window.dispatchEvent(new Event('cmux-ui-scale-change'))"
    }
    /// `agentPane.zoom`, the focused agent chat's own display scale.
    public var agentPaneZoom: CGFloat = 1
    /// `ui.animationSpeed`: how fast chrome animates (see `Motion`). A change posts
    /// `Motion.speedDidChange` and tells `motionChanges`, for hosts outside Observation (a video
    /// wallpaper's player).
    public var animationSpeed: MotionSpeed = .fast {
        didSet {
            guard animationSpeed != oldValue else { return }
            motionChanges.post(.speed)
        }
    }
    /// `ui.animations.enabled`, the master motion switch: false makes every
    /// animation in the app instant, whatever the category switches say
    /// (``MotionGate``). Posts `Motion.speedDidChange` like the speed.
    public var animationsEnabled = true {
        didSet {
            guard animationsEnabled != oldValue else { return }
            motionChanges.post(.speed)
        }
    }
    /// The categories whose `ui.animations.<category>` is false: their
    /// animations are instant (``MotionCategory``). Posts `Motion.speedDidChange`.
    public var disabledAnimationCategories: Set<MotionCategory> = [] {
        didSet {
            guard disabledAnimationCategories != oldValue else { return }
            motionChanges.post(.speed)
        }
    }
    /// `appearance.colorTransition.*`: how theme and color changes animate (``ColorTransition``;
    /// read it resolved through `ColorTransition.current`). Web pages take a new value with their
    /// next theme payload.
    public var colorTransition = ColorTransition()
    /// `appearance.inactiveWindowDim`: how much more of the theme color covers a window that is
    /// not key (``WindowMaterialView``); 0, the default, keeps its look. Posts
    /// `WindowMaterialView.inactiveDimDidChange`.
    public var inactiveWindowDim = 0.0 {
        didSet {
            guard inactiveWindowDim != oldValue else { return }
            NotificationCenter.default.post(name: WindowMaterialView.inactiveDimDidChange, object: nil)
        }
    }
    /// `appearance.wallpaperTint`: where the desktop shows through the window, its tint takes the
    /// desktop picture's hue (``WallpaperTint``), as macOS tints its own windows. Off until the
    /// setting reaches it (``SettingsApplier``).
    public var wallpaperTint = false {
        didSet {
            guard wallpaperTint != oldValue else { return }
            BackdropImageStore.shared.desktop.tintEnabled = wallpaperTint
        }
    }
    /// `ui.animations.bounce`: structural springs are critically damped or bounce subtly.
    public var animationBounce: MotionBounce = .none
    /// The `ui.animations.{newTab,newWorkspace}` kinds on: new tabs by default
    /// (`AnimationKindsSetting.defaultEnabled`), new workspaces off.
    public var enabledAnimations: Set<MotionKind> = [.newTab]
    /// `ui.paneAnimations`: pane layout changes spring when true (see
    /// `Motion.animatesPaneLayout`); on by default.
    public var paneAnimations = true
    /// `labs.classicHome`: Home is the classic top page instead of the home workspace with its
    /// left dock (cx-ebm.59.5); off by default, kept one release. Read when Home opens.
    public var classicHome = false
    /// `home.channelsEnabled`: the sidebar shows the Channels entry after Home (cx-frn2y); off by default.
    public var homeChannelsEnabled = false
    /// `home.chiefBubbleStyle` is `theme`: the Chief chat's bubbles take the theme's colours; false (the
    /// default) keeps iMessage's blue and grey. The Home transcript follows it (`HomeNativeTranscriptView.bubbleStyle`).
    public var homeChiefBubblesThemed = false
    /// `home.bubbleColors.*`: the bubble colours every Home chat starts with, `#RRGGBB` by role (`sent`,
    /// `sentText`, `received`, `receivedText`); empty keeps the bubble style's. A chat's own Chat Colors… go over it.
    public var homeBubbleColors: [String: String] = [:]
    /// `home.chiefPetEnabled`: the floating Chief pet shows; the empty Chief conversation's pet row follows it.
    public var homeChiefPetEnabled = false
    /// Per-metric overrides in points, clamped by `setOverride`.
    public private(set) var overrides: [MetricKey: CGFloat] = [:]
    /// Pane padding, corner radius and border from cmux.json `layout.*`,
    /// clamped by `setPaneChrome`.
    public private(set) var paneChrome = PaneChromeOverrides()
    /// `layout.centerFocusedColumn`.
    public var centerFocusedColumn: CenterFocusedColumn = .never
    /// `tabs.overflow`: crowded tab strips shrink their tabs (default) or scroll sooner.
    public var tabOverflow: TabOverflow = .shrink
    /// `layout.stripScrollbar`: the column strip's scrollbar.
    public var stripScrollbar: StripScrollbarMode = .system
    /// `sidebar.*`: section look and pinned band caps.
    public var sidebarSections = SidebarSectionsPreferences.defaults
    /// `sidebar.hoverCards.enabled`: off, no hover card opens on hover (sidebar rows, tabs, and a
    /// user's custom card). A change posts `hoverCardsDidChange` so a shown card goes at once.
    public var hoverCardsEnabled = true {
        didSet {
            guard hoverCardsEnabled != oldValue else { return }
            NotificationCenter.default.post(name: Self.hoverCardsDidChange, object: nil)
        }
    }
    /// `ui.calm` (``CalmMode``): Reduce Motion behavior, no hover cards and no hover fills, and
    /// with `still` no animation at all. A change posts the motion, Reduce Motion and hover-card
    /// notifications, so cached motion values re-read and a shown card goes at once.
    public var calmMode: CalmMode = .off {
        didSet {
            guard calmMode != oldValue else { return }
            motionChanges.post(.speed)
            motionChanges.post(.reduceMotion)
            NotificationCenter.default.post(name: Self.hoverCardsDidChange, object: nil)
            ThemeScope.app.store.repaintAll()
        }
    }
    /// Hover cards open on hover: `sidebar.hoverCards.enabled` and not calm mode.
    public var showsHoverCards: Bool { hoverCardsEnabled && calmMode.showsHoverEffects }
    /// The pointer paints a hover fill on tabs, sidebar rows and chrome buttons (off in calm mode).
    public var showsHoverFills: Bool { calmMode.showsHoverEffects }
    /// `sidebar.hoverCards.delay`: pointer rest before a sidebar row's or a tab's card opens.
    /// Defaults to `HoverCardTiming.showDelay`.
    public var hoverCardDelay: Duration = HoverCardTiming.showDelay
    /// `sidebar.hoverCards.layout`, `.sections.*` and `.maxRows`: what a workspace card shows (u3320).
    public var workspaceHoverCard = WorkspaceHoverCardOptions()
    /// `sidebar.hoverCards.groups.*`: whether group headers and tab group chips open a card, after
    /// how long, and what it shows (Lawrence 2026-10-20).
    public var groupHoverCard = GroupHoverCardOptions()
    /// `layout.closeFocus`: who gets focus when the focused pane closes.
    public var closeFocus: CloseFocusPolicy = .previousNeighbor
    /// `layout.defaultColumnWidth`: new column width, a viewport fraction.
    public var defaultColumnWidth: Double = 2.0 / 3.0
    /// `layout.newColumnWidth`: how a new column's width is chosen.
    public var newColumnWidth: NewColumnWidthMode = .fixed
    /// `layout.splitSizing`: what a split does to its column.
    public var splitSizing: SplitSizing = .even
    /// `layout.dockColumnEdge`, `layout.dockColumnMode`.
    public var dockColumnEdge: DockDefaultEdge = .nearest
    public var dockColumnMode: DockDefaultMode = .docked
    /// `layout.frameOrientation`: column-major (side docks full height) or
    /// row-major (top and bottom docks full width), plans/cmux-next/layout-model.md.
    public var frameOrientation: FrameOrientation = .columnMajor
    /// `layout.rows`: off hides every row entry point and fits existing
    /// rows into their column (plans/cmux-next/rows.md O1 to O3).
    public var layoutRows = true
    /// `layout.focusFollowsMouse`: hovering or scrolling an unfocused pane focuses it (default off).
    public var focusFollowsMouse = false
    /// `layout.scrollAreas`: a split that cannot fit scrolls instead of squashing its panes
    /// (plans/cmux-next/scroll-areas-DESIGN.md). Off by default.
    public var layoutScrollAreas = false
    /// `layout.scrollModifier`: Command + scroll moves the layout and a plain scroll goes to the
    /// pane under the pointer (`command`, default), or the rule before it (`none`).
    public var layoutScrollModifier: LayoutScrollModifier = .command
    /// `layout.pagesHandleCommandScroll`: a web page that cancels Command + wheel (Figma,
    /// Excalidraw zoom) keeps a Command scroll that starts over it; on by default.
    public var pagesHandleCommandScroll = true
    /// `layout.minimumPaneWidth`, `layout.minimumPaneHeight`: the smallest
    /// content area a pane keeps below its chrome, in points.
    public var minimumPaneContentSize = CGSize(width: 200, height: 64)
    /// `focusRing.*`: the focused pane's ring or glow.
    public var focusRing = FocusRingSettings()
    /// `sidebar.border` and `sidebar.borderWidth`.
    public var sidebarBorder = SidebarBorder()
    /// `notifications.attention.*`: the unread pane's attention ring.
    public var attention = AttentionSettings()
    /// `appearance.statusIndicator.*`: loading and status indicators on
    /// sidebar rows, tabs, sections and pane headers.
    public var statusIndicator = StatusIndicatorSettings()
    /// cmux's terminal font override (`terminal.fontFamily` in cmux.json),
    /// so chrome that imitates the terminal (the braille status indicator)
    /// draws in it. Nil (no override) uses the system monospaced font there;
    /// pages use `effectiveTerminalFontFamily`, which also reads the Ghostty config.
    public var terminalFontFamily: String? {
        didSet { repaintIfTerminalFaceChanged(from: oldValue ?? terminalConfigFontFamily) }
    }
    /// The Ghostty config files' own `font-family` (`GhosttyConfigFontFamily`), the terminal's
    /// face when cmux.json sets none.
    public var terminalConfigFontFamily: String? {
        didSet { repaintIfTerminalFaceChanged(from: terminalFontFamily ?? oldValue) }
    }
    /// The family the terminal draws in: cmux.json's, else the Ghostty config's; nil when
    /// neither names one (Ghostty's built-in face). Pages that show code follow it (`WebTheme`).
    public var effectiveTerminalFontFamily: String? { terminalFontFamily ?? terminalConfigFontFamily }
    /// Pages that show code draw in the terminal's face (`WebTheme.Terminal`): a change of it
    /// repaints, so every page resends its theme.
    private func repaintIfTerminalFaceChanged(from before: String?) {
        if effectiveTerminalFontFamily != before { ThemeScope.app.store.repaintAll() }
    }
    /// `status.*`: inferred command busy and run notifications.
    public var statusBehavior = StatusBehaviorSettings()
    /// `appearance.borders`: default, or none (no border, hairline or
    /// separator anywhere; `Borders`).
    public var borders: BorderMode = .default
    /// `appearance.sidebarSurface`: the sidebar on the main pane's surface,
    /// or shaded apart from it.
    public var sidebarSurface: SidebarSurface = .same
    /// `appearance.chromeStyle`: the window look whose defaults the finer
    /// keys refine (`ChromeStyle`).
    public var chromeStyle: ChromeStyle = .default
    /// `appearance.focusIndicator`: what marks the focused pane.
    public var focusIndicator: FocusIndicator = .tabs
    /// `focus.inactiveTabStyle`: how an unfocused pane's tabs draw subtler
    /// when `focusIndicator` marks tabs.
    public var inactiveTabStyle: InactiveTabStyle = .fade
    /// The Ghostty config's `unfocused-split-opacity` and
    /// `unfocused-split-fill`; no dim unless the config sets one.
    public var unfocusedPaneDim = UnfocusedPaneDim()

    /// `focusIndicator` unless Debug Settings overrides it.
    public var effectiveFocusIndicator: FocusIndicator { FocusIndicatorTunables.indicator.override ?? focusIndicator }
    /// `inactiveTabStyle` unless Debug Settings overrides it.
    public var effectiveInactiveTabStyle: InactiveTabStyle { FocusIndicatorTunables.inactiveTabStyle.override ?? inactiveTabStyle }
    /// `window.titlebar`: minimal (no titlebar strip) or standard.
    public var titlebar: TitlebarStyle = .minimal
    /// `window.titlebarButtons`.
    public var titlebarButtons: TitlebarButtonsMode = .hover
    /// `tabs.plusButton`.
    public var plusButton: PlusButtonMode = .hover
    /// `sidebar.side` (R109).
    public var sidebarSide: SidebarSide = .left
    /// `sidebar.spacesPosition` (R109).
    public var spacesPosition: SpacesPosition = .bottom
    /// `sidebar.spacesVisibility` (cx-5k3r).
    public var spacesVisibility: SpacesVisibilityMode = .hover
    /// `tabs.barPosition` (R109).
    public var tabBarPosition: TabBarPosition = .top
    /// `tabs.barOrder` (R109).
    public var tabBarOrder: TabBarOrder = .aboveToolbar
    /// `browser.toolbarPosition`: the omnibar row above or below the page.
    public var browserToolbarPosition: ToolbarPosition = .top
    /// `appearance.paneBackgrounds`: one background for the window or a copy per pane.
    public var paneBackgrounds: PaneBackgroundMode = .shared

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
        case .tabMinActiveWidth: 32...200
        case .tabMinInactiveWidth: 16...120
        case .tabPinnedWidth: 24...120
        case .paletteRowHeight: 26...48
        case .columnGap: 0...24
        case .dividerThickness: 0...6
        case .dividerHitWidth: 1...24
        case .panelCornerRadius: 0...20
        case .chromeFontSize: 10...16
        case .tabFontSize: 10...18
        case .titlebarHeight: 24...56
        }
    }

    /// Clamps the app-wide interface scale to the supported range.
    public static func clampedUIScale(_ value: CGFloat) -> CGFloat {
        min(max(value, 0.85), 1.5)
    }

    public static func clampedInterfaceScale(_ value: CGFloat) -> CGFloat {
        min(max(value, 0.9), 1.25)
    }
}

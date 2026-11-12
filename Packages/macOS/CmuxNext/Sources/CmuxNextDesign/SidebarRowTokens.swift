public import CmuxNextDesignTokens
public import CoreGraphics

/// The sidebar's row tokens under `sidebar.density` and `sidebar.textSize` (cx-13w3), from the
/// app's density tokens: the one place the sidebar's rows (SidebarDensityTokens) and its cards
/// (``SidebarCardMetrics``, the Updated card's page through ``WebTheme``) read row height, inset,
/// corner and text size. Compact and Expanded keep the app tokens; Comfortable adds `space2` to a
/// row and steps the inset from `space3` to `space4`. Pure, so a test lays out every density.
public nonisolated struct SidebarRowTokens: Equatable, Sendable {
    /// The app density's tokens the sidebar builds on.
    public struct Base: Equatable, Sendable {
        public var rowHeight: CGFloat
        public var space1: CGFloat
        public var space2: CGFloat
        public var space3: CGFloat
        public var space4: CGFloat
        /// `Metrics.itemCornerRadius`: every row fill's corner.
        public var cornerRadius: CGFloat
        /// The body and caption text sizes (`Typography.body`, `Typography.caption`).
        public var body: CGFloat
        public var caption: CGFloat
        /// The app is at Default density (`appearance.density` cozy), the Codex desktop app's size (#37274), so the
        /// sidebar's own Compact rows take the Codex sidebar's geometry (``matchesCodex``).
        public var isCodexDensity: Bool

        public init(rowHeight: CGFloat, space1: CGFloat, space2: CGFloat, space3: CGFloat, space4: CGFloat,
                    cornerRadius: CGFloat, body: CGFloat, caption: CGFloat, isCodexDensity: Bool = false) {
            self.rowHeight = rowHeight
            self.space1 = space1
            self.space2 = space2
            self.space3 = space3
            self.space4 = space4
            self.cornerRadius = cornerRadius
            self.body = body
            self.caption = caption
            self.isCodexDensity = isCodexDensity
        }
    }

    public let density: SidebarDensity
    public let textSize: SidebarTextSize
    public let base: Base

    public init(density: SidebarDensity, textSize: SidebarTextSize, base: Base) {
        self.density = density
        self.textSize = textSize
        self.base = base
    }

    public var isComfortable: Bool { density == .comfortable }
    /// A comfortable row's extra height, plus the text size's.
    public var extraHeight: CGFloat { Self.extraHeight(density: density, textSize: textSize, space2: base.space2) }

    /// The rule behind ``extraHeight``, on its inputs alone: `Metrics.chromeRowHeight` reads it
    /// without building the whole token set, whose corner radius depends on the tab height.
    /// - Parameters:
    ///   - density: `sidebar.density`.
    ///   - textSize: `sidebar.textSize`.
    ///   - space2: The density's `space2`, a comfortable row's extra height.
    /// - Returns: The height a one-line row adds to the app density's row.
    public static func extraHeight(density: SidebarDensity, textSize: SidebarTextSize, space2: CGFloat) -> CGFloat {
        (density == .comfortable ? space2 : 0) + textSize.rowStep
    }
    /// A one-line workspace row, group header or band row.
    public var rowHeight: CGFloat { base.rowHeight + extraHeight }
    /// The tokens of the bands above the list (Home, pinned rows) and of the workspace hover card: at
    /// Expanded, Comfortable's, since Expanded keeps the app's one-line row and grows only the list's
    /// workspace rows by a detail line (pinned rows were too short, Lawrence 2026-11-04). Compact and
    /// Comfortable keep their own.
    public var band: SidebarRowTokens {
        density == .expanded ? SidebarRowTokens(density: .comfortable, textSize: textSize, base: base) : self
    }
    /// Rows inset from the sidebar edge (and, outside ``matchesCodex``, their content from the row edge).
    public var horizontalInset: CGFloat { isComfortable ? base.space4 : base.space3 }

    /// The sidebar's list and band rows draw the Codex desktop sidebar's rows
    /// (https://github.com/manaflow-ai/cmux/issues/39956, measured in https://github.com/manaflow-ai/cmux/issues/28793): the app at
    /// Default density and the sidebar at its own default, Compact. Codex stacks 30 px rows with no gap
    /// (`--height-token-nav-row`), pads their content 8 px from the fill (`--padding-row-x`) inside a 6 px outer
    /// inset, and rounds the fill 10 px (`--radius-token-row`). Every other density keeps its own rows, so
    /// `appearance.density`, `sidebar.density` and the metric overrides still pick them.
    public var matchesCodex: Bool { base.isCodexDensity && density == .compact }
    /// A list or band row's height: the row and the gap under it as one fill when ``matchesCodex``, so the pitch
    /// stays the row step and the fill grows into the gap (28 + 2 = 30 at Default).
    public var listRowHeight: CGFloat { rowHeight + Self.listFillGain(isCodexDensity: base.isCodexDensity, density: density, space1: base.space1) }
    /// The rule behind ``listRowHeight``'s growth into the gap, on its inputs alone: `Metrics.chromeRowHeight`
    /// reads it without building the whole token set.
    /// - Parameters:
    ///   - isCodexDensity: The app is at Default density (``Base/isCodexDensity``).
    ///   - density: `sidebar.density`.
    ///   - space1: The density's `space1`, the gap a ``matchesCodex`` row fills.
    /// - Returns: The height a list row's fill adds to ``rowHeight``.
    public static func listFillGain(isCodexDensity: Bool, density: SidebarDensity, space1: CGFloat) -> CGFloat {
        isCodexDensity && density == .compact ? space1 : 0
    }
    /// The gap between list rows keeps adjacent hover and selection fills apart.
    public var rowGap: CGFloat { base.space1 }
    /// A row's content (icon, title, trailing marks) from its fill's edge: `space4` (8 pt) when ``matchesCodex``,
    /// else the outer inset.
    public var contentInset: CGFloat { matchesCodex ? base.space4 : horizontalInset }
    /// The Codex row corner exported to pages that share the sidebar row geometry.
    public var codexCornerRadius: CGFloat? { matchesCodex ? (listRowHeight / 3).rounded() : nil }
    /// A row title's and a detail line's text size.
    public var titleSize: CGFloat { base.body + textSize.textStep }
    public var captionSize: CGFloat { base.caption + textSize.textStep }

    /// The sidebar's cards at this density: the rows' inset and text, a title line's room above and
    /// below it as a row gives its text, a button one row tall less the rows' gap, the rows' corner
    /// on the button and that corner plus the padding on the card (nested radii).
    public var card: SidebarCardMetrics {
        let paddingY = isComfortable ? base.space3 : base.space2
        return SidebarCardMetrics(
            paddingX: horizontalInset, paddingY: paddingY, gap: isComfortable ? base.space2 : base.space1,
            cornerRadius: base.cornerRadius + paddingY, titleSize: titleSize, noteSize: captionSize,
            buttonHeight: rowHeight - 2 * base.space1, buttonPaddingX: horizontalInset, buttonRadius: base.cornerRadius,
            closeSide: rowHeight - 2 * base.space2)
    }

    /// A list row's height, corner and content inset as `--cmux-sidebar-row-*` CSS px of a page zoomed
    /// by `pageZoom`: pages whose rows match the sidebar's (Settings) read them. The values are the
    /// list row's (``listRowHeight``, ``codexCornerRadius``, ``contentInset``), so at Default a page
    /// row is Codex's 30 px row with a 10 px corner and 8 px content inset, as the sidebar draws it.
    public func rowCSSVariables(pageZoom: CGFloat) -> [String: String] {
        let zoom = max(pageZoom, 0.01)
        return [
            "--cmux-sidebar-row-height": SidebarCardMetrics.px(listRowHeight / zoom),
            "--cmux-sidebar-row-radius": SidebarCardMetrics.px((codexCornerRadius ?? base.cornerRadius) / zoom),
            "--cmux-sidebar-row-inset": SidebarCardMetrics.px(contentInset / zoom),
        ]
    }

    /// The app's tokens now (`Metrics`, `Typography`) under the sidebar's settings.
    @MainActor public static var current: SidebarRowTokens {
        let sections = DesignSettings.shared.sidebarSections
        let base = Base(rowHeight: Metrics.sidebarRowHeight, space1: Metrics.space1, space2: Metrics.space2,
                        space3: Metrics.space3, space4: Metrics.space4, cornerRadius: Metrics.itemCornerRadius,
                        body: Typography.body.pointSize, caption: Typography.caption.pointSize,
                        isCodexDensity: Metrics.tokens.id == DensityPreset.cozy.rawValue)
        return SidebarRowTokens(density: sections.density, textSize: sections.textSize, base: base)
    }
}

/// The sidebar's card sizes at one density (``SidebarRowTokens/card``), in points: the native host
/// draws its glass and x with them, and the card's page reads them as `--cmux-sidebar-card-*`.
public nonisolated struct SidebarCardMetrics: Equatable, Sendable {
    public var paddingX: CGFloat
    public var paddingY: CGFloat
    /// Between the title, the note and the button row.
    public var gap: CGFloat
    public var cornerRadius: CGFloat
    public var titleSize: CGFloat
    public var noteSize: CGFloat
    public var buttonHeight: CGFloat
    public var buttonPaddingX: CGFloat
    public var buttonRadius: CGFloat
    /// The native x's side.
    public var closeSide: CGFloat

    public init(paddingX: CGFloat, paddingY: CGFloat, gap: CGFloat, cornerRadius: CGFloat, titleSize: CGFloat, noteSize: CGFloat,
                buttonHeight: CGFloat, buttonPaddingX: CGFloat, buttonRadius: CGFloat, closeSide: CGFloat) {
        self.paddingX = paddingX
        self.paddingY = paddingY
        self.gap = gap
        self.cornerRadius = cornerRadius
        self.titleSize = titleSize
        self.noteSize = noteSize
        self.buttonHeight = buttonHeight
        self.buttonPaddingX = buttonPaddingX
        self.buttonRadius = buttonRadius
        self.closeSide = closeSide
    }

    public static let cssKeys = [
        "--cmux-sidebar-card-padding-x", "--cmux-sidebar-card-padding-y", "--cmux-sidebar-card-gap",
        "--cmux-sidebar-card-radius", "--cmux-sidebar-card-title", "--cmux-sidebar-card-note",
        "--cmux-sidebar-card-button", "--cmux-sidebar-card-button-padding-x", "--cmux-sidebar-card-button-radius",
        "--cmux-sidebar-card-close",
    ]

    /// The sizes in CSS px of a page zoomed by `pageZoom` (the interface scale: a CSS px is
    /// `pageZoom` points), so the page draws the rows' point sizes at any zoom.
    public func cssVariables(pageZoom: CGFloat) -> [String: String] {
        let zoom = max(pageZoom, 0.01)
        let values = [paddingX, paddingY, gap, cornerRadius, titleSize, noteSize, buttonHeight, buttonPaddingX, buttonRadius, closeSide]
        return Dictionary(uniqueKeysWithValues: zip(Self.cssKeys, values.map { Self.px($0 / zoom) }))
    }

    /// "6px", "10.5px": at most two decimals, no trailing zeros.
    static func px(_ value: CGFloat) -> String {
        let rounded = (value * 100).rounded() / 100
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%g", Double(rounded))
        return text + "px"
    }
}

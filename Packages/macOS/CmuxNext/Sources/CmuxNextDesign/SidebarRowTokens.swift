public import CmuxNextDesignTokens
public import CoreGraphics

/// The sidebar's row tokens under `sidebar.density`, `sidebar.textSize` and the person's own sizes
/// (cx-13w3): the one place the sidebar's rows (SidebarDensityTokens) and its cards
/// (``SidebarCardMetrics``, the Updated card's page through ``WebTheme``) read row height, inset,
/// corner and text size. Pure, so a test lays out every density.
///
/// Normal, the default, is the Codex desktop sidebar (https://github.com/manaflow-ai/cmux/issues/28793):
/// 13 pt titles at weight 430, 12 pt details, a 28 pt row on a 30 pt pitch, an 8 pt inset. Every other
/// density is Normal at its ``SidebarDensity/scale``, whole points for lengths and half points for text.
/// Expanded keeps Normal's one-line tokens. A custom size (`sidebar.titleSize`, `detailSize`, `rowHeight`,
/// `rowPadding`) wins.
public nonisolated struct SidebarRowTokens: Equatable, Sendable {
    /// The app density's tokens the sidebar builds on.
    public struct Base: Equatable, Sendable {
        /// The app's one-line sidebar row (`Metrics.sidebarRowHeight`): Compact's row.
        public var rowHeight: CGFloat
        public var space1: CGFloat
        public var space2: CGFloat
        public var space3: CGFloat
        public var space4: CGFloat
        /// `Metrics.itemCornerRadius`: every row fill's corner.
        public var cornerRadius: CGFloat
        /// The body and caption text sizes (`Typography.body`, `Typography.caption`): Compact's text.
        public var body: CGFloat
        public var caption: CGFloat
        /// The list's Codex row (`Metrics.sidebarListRowHeight`) and text (`Typography.sidebarRow`,
        /// `Typography.sidebarDetail`) every other density builds on.
        public var listRowHeight: CGFloat
        public var rowTitle: CGFloat
        public var rowDetail: CGFloat
        /// The person's own sizes, already scaled to the Interface Size; nil leaves each to the density.
        public var customRowHeight: CGFloat?
        public var customRowPadding: CGFloat?
        public var customTitle: CGFloat?
        public var customDetail: CGFloat?

        /// The Codex sizes default to Compact's when not given, so a base built for Compact alone reads as before.
        public init(rowHeight: CGFloat, space1: CGFloat, space2: CGFloat, space3: CGFloat, space4: CGFloat,
                    cornerRadius: CGFloat, body: CGFloat, caption: CGFloat, listRowHeight: CGFloat? = nil,
                    rowTitle: CGFloat? = nil, rowDetail: CGFloat? = nil, customRowHeight: CGFloat? = nil,
                    customRowPadding: CGFloat? = nil, customTitle: CGFloat? = nil, customDetail: CGFloat? = nil) {
            self.rowHeight = rowHeight
            self.space1 = space1
            self.space2 = space2
            self.space3 = space3
            self.space4 = space4
            self.cornerRadius = cornerRadius
            self.body = body
            self.caption = caption
            self.listRowHeight = listRowHeight ?? rowHeight
            self.rowTitle = rowTitle ?? body
            self.rowDetail = rowDetail ?? caption
            self.customRowHeight = customRowHeight
            self.customRowPadding = customRowPadding
            self.customTitle = customTitle
            self.customDetail = customDetail
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

    /// This density's size against Normal.
    public var scale: CGFloat { CGFloat(density.scale) }
    /// A length at this density, in whole points.
    public func scaled(_ value: CGFloat) -> CGFloat { Self.length(value, density: density) }
    /// A length at `density`, in whole points. Normal returns `value` exactly.
    public static func length(_ value: CGFloat, density: SidebarDensity) -> CGFloat {
        density.scale == 1 ? value : (value * CGFloat(density.scale)).rounded()
    }
    /// A text size at `density`, in half points. Normal returns `value` exactly, so a size the Interface
    /// Size or chrome font scaled off the half-point grid stays as it is.
    public static func text(_ value: CGFloat, density: SidebarDensity) -> CGFloat {
        density.scale == 1 ? value : (value * CGFloat(density.scale) * 2).rounded() / 2
    }
    /// The text size's steps over this density's sizes.
    public var textSteps: SidebarTextSize.Steps { textSize.steps }
    /// The text size's extra height on a row or header.
    public var extraHeight: CGFloat { textSteps.row }
    /// A one-line workspace row, group header or band row: `sidebar.rowHeight` when set.
    public var rowHeight: CGFloat {
        if let custom = base.customRowHeight { return custom }
        return scaled(base.listRowHeight) + extraHeight
    }
    /// Rows inset from the sidebar edge, and their content from the row edge: `sidebar.rowPadding` when set;
    /// else Codex's 8 pt `--padding-row-x` at this density's scale.
    public var horizontalInset: CGFloat {
        if let custom = base.customRowPadding { return custom }
        return scaled(base.space4)
    }
    /// A row title's and a detail line's text size: `sidebar.titleSize` / `sidebar.detailSize` when set.
    public var titleSize: CGFloat { base.customTitle ?? (Self.text(base.rowTitle, density: density) + textSteps.text) }
    public var captionSize: CGFloat { base.customDetail ?? (Self.text(base.rowDetail, density: density) + textSteps.text) }

    /// The sidebar's cards at this density: the rows' inset and text, a title line's room above and
    /// below it as a row gives its text, a button one row tall less the rows' gap, the rows' corner
    /// on the button and that corner plus the padding on the card (nested radii).
    public var card: SidebarCardMetrics {
        let paddingY = scaled(base.space2)
        let corner = scaled(base.cornerRadius)
        return SidebarCardMetrics(
            paddingX: horizontalInset, paddingY: paddingY, gap: scaled(base.space1),
            cornerRadius: corner + paddingY, titleSize: titleSize, noteSize: captionSize,
            buttonHeight: rowHeight - 2 * base.space1, buttonPaddingX: horizontalInset, buttonRadius: corner,
            closeSide: rowHeight - 2 * base.space2)
    }

    /// The app's tokens now (`Metrics`, `Typography`) under the sidebar's settings.
    @MainActor public static var current: SidebarRowTokens {
        let sections = DesignSettings.shared.sidebarSections
        let base = Base(rowHeight: Metrics.sidebarRowHeight, space1: Metrics.space1, space2: Metrics.space2,
                        space3: Metrics.space3, space4: Metrics.space4, cornerRadius: Metrics.itemCornerRadius,
                        body: Typography.body.pointSize, caption: Typography.caption.pointSize,
                        listRowHeight: Metrics.sidebarListRowHeight, rowTitle: Typography.sidebarRow.pointSize,
                        rowDetail: Typography.sidebarDetail.pointSize,
                        customRowHeight: sections.rowHeight.map { Metrics.scale($0) },
                        customRowPadding: sections.rowPadding.map { Metrics.scale($0) },
                        customTitle: sections.titleSize.map { $0 * Typography.userScale },
                        customDetail: sections.detailSize.map { $0 * Typography.userScale })
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

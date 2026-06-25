public import AppKit
public import Bonsplit

/// Pure diff/plan core for applying terminal background chrome to a Bonsplit
/// window's tab-bar appearance.
///
/// Both `Workspace.applyGhosttyChrome(...)` twins follow the same shape:
/// gather the current appearance and the next background inputs, compute which
/// appearance fields changed (`colorsChanged` / `sharedBackdropChanged` /
/// `fontSizeChanged`, collapsing to `isNoOp` when none did), assign only the
/// changed fields, and log. ``ChromeApplyPlan`` extracts the middle step: it
/// resolves the next chrome colors with ``BonsplitChromeColorResolver`` and
/// produces the field-level diff plus the resolved values, so the caller is
/// left with gathering inputs, applying ``changedFields``, and logging.
///
/// Holds no mutable state. The tab-title font size is optional so the two twins
/// share one plan: the config twin passes a non-`nil` `nextTabTitleFontSize`
/// (font participates in the diff), while the background-only twin passes `nil`
/// (font is never part of the plan, matching the legacy behavior exactly).
public struct ChromeApplyPlan: Sendable {
    /// The current Bonsplit appearance fields the plan diffs against.
    public struct Current: Sendable {
        /// The current chrome color set.
        public let chromeColors: BonsplitConfiguration.Appearance.ChromeColors
        /// Whether the current appearance shares the window backdrop.
        public let usesSharedBackdrop: Bool
        /// The current tab-title font size.
        public let tabTitleFontSize: CGFloat

        /// Creates the current-appearance snapshot the plan diffs against.
        public init(
            chromeColors: BonsplitConfiguration.Appearance.ChromeColors,
            usesSharedBackdrop: Bool,
            tabTitleFontSize: CGFloat
        ) {
            self.chromeColors = chromeColors
            self.usesSharedBackdrop = usesSharedBackdrop
            self.tabTitleFontSize = tabTitleFontSize
        }
    }

    /// The next background inputs the plan resolves into chrome colors.
    public struct NextInputs: Sendable {
        /// The terminal background color to composite into chrome colors.
        public let backgroundColor: NSColor
        /// The terminal background opacity.
        public let backgroundOpacity: Double
        /// Whether the window root backdrop owns terminal fills.
        public let sharesWindowBackdrop: Bool
        /// How the terminal surface backdrop is rendered.
        public let renderingMode: GhosttyTerminalBackdropRenderingMode
        /// The next tab-title font size, or `nil` to exclude the font from the
        /// plan (the background-only twin never touches font size).
        public let tabTitleFontSize: CGFloat?

        /// Creates the next-input set the plan resolves.
        public init(
            backgroundColor: NSColor,
            backgroundOpacity: Double,
            sharesWindowBackdrop: Bool,
            renderingMode: GhosttyTerminalBackdropRenderingMode,
            tabTitleFontSize: CGFloat?
        ) {
            self.backgroundColor = backgroundColor
            self.backgroundOpacity = backgroundOpacity
            self.sharesWindowBackdrop = sharesWindowBackdrop
            self.renderingMode = renderingMode
            self.tabTitleFontSize = tabTitleFontSize
        }
    }

    /// The set of appearance fields the plan would change.
    public struct ChangedFields: Sendable {
        /// Whether the resolved chrome colors differ from the current set.
        public let colors: Bool
        /// Whether the shared-backdrop flag differs from the current value.
        public let sharedBackdrop: Bool
        /// Whether the tab-title font size differs (always `false` when the
        /// font was excluded from the plan).
        public let fontSize: Bool
    }

    /// The chrome colors resolved from ``NextInputs``.
    public let nextChromeColors: BonsplitConfiguration.Appearance.ChromeColors
    /// Whether the next appearance shares the window backdrop.
    public let nextUsesSharedBackdrop: Bool
    /// The next tab-title font size, or `nil` when the font was excluded.
    public let nextTabTitleFontSize: CGFloat?
    /// Which appearance fields changed relative to the current appearance.
    public let changedFields: ChangedFields

    /// Whether nothing changed (the caller should skip the apply step).
    public var isNoOp: Bool {
        !changedFields.colors && !changedFields.sharedBackdrop && !changedFields.fontSize
    }

    /// Computes the chrome apply plan: resolves the next chrome colors from
    /// `next` and diffs them, the shared-backdrop flag, and (when present) the
    /// tab-title font size against `current`.
    /// - Parameters:
    ///   - current: The current Bonsplit appearance fields.
    ///   - next: The next background inputs to resolve and diff.
    ///   - resolver: The color resolver used for chrome-color math.
    public init(
        current: Current,
        next: NextInputs,
        resolver: BonsplitChromeColorResolver
    ) {
        let resolvedColors = resolver.chromeColors(
            backgroundColor: next.backgroundColor,
            backgroundOpacity: next.backgroundOpacity,
            sharesWindowBackdrop: next.sharesWindowBackdrop,
            renderingMode: next.renderingMode
        )
        self.nextChromeColors = resolvedColors
        self.nextUsesSharedBackdrop = next.sharesWindowBackdrop
        self.nextTabTitleFontSize = next.tabTitleFontSize

        let colorsChanged = !resolver.chromeColorsEqual(current.chromeColors, resolvedColors)
        let sharedBackdropChanged = current.usesSharedBackdrop != next.sharesWindowBackdrop
        let fontSizeChanged: Bool
        if let nextFontSize = next.tabTitleFontSize {
            fontSizeChanged = abs(current.tabTitleFontSize - nextFontSize) > 0.0001
        } else {
            fontSizeChanged = false
        }
        self.changedFields = ChangedFields(
            colors: colorsChanged,
            sharedBackdrop: sharedBackdropChanged,
            fontSize: fontSizeChanged
        )
    }
}

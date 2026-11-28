public import CoreGraphics
public import CmuxNextDesignTokens

/// The menu and popover look a theme file sets (`appearance.menu.*`, `appearance.popover.*`): the
/// panel's corner, edge, shadow and fill, the rows' padding, height and hover corner, and how the
/// shortcut column, section labels, separators, destructive rows, submenus and second lines draw.
/// Leo, 2026-11-19: "i think y'all also ought to emulate the things for context menu styling and such
/// maybne in those repos too and the layout and proportions as well" / "if it cant be hot swapped,
/// that's probably an issue with our api/sdk".
///
/// Every field's unset value (nil, or `.standard`) is today's look, so a file that sets none of these
/// keys changes nothing. The schema rows (schemas/settings/source/appearance.json, list `menuLook`)
/// hold the ranges, and the daemon validates a value before it reaches here; `MenuLookSetting` parses
/// the snapshot into this. The App's own menus (``GlassMenu`` and its submenus) read it at each open;
/// pages read it as the look tokens ``WebTheme`` pushes on every change (``webVariables``): the
/// `--menu-*` tokens a look sets (webviews/src/ui/README.md, "Menu tokens a look sets") and the
/// popover's `--popover-*`. Standard right-click menus stay `NSMenu` (Lawrence 2026-10-23) and keep
/// the system's look.
public nonisolated struct MenuLook: Equatable, Sendable {
    /// The menu panel's corner; nil: the popup radius.
    public var cornerRadius: CGFloat?
    /// The panel's hairline edge as a share of the text color, 0...1; nil: today's 12%.
    public var borderOpacity: CGFloat?
    public var shadow: Shadow = .standard
    /// The panel's fill over the glass; nil: the glass and its veil.
    public var fill: ThemeRGB?
    /// The panel's inner padding, which is also the hover fill's inset from its edges; nil:
    /// ``MenuMetrics/highlightInset``.
    public var padding: CGFloat?
    /// The hover fill's corner; nil: today's.
    public var highlightRadius: CGFloat?
    /// A one-line row's height; nil: the density's control row.
    public var rowHeight: CGFloat?
    public var shortcuts: Ink = .standard
    public var sectionLabel: Ink = .standard
    public var separator: Separator = .standard
    public var destructiveInk: DestructiveInk = .standard
    public var submenu: Submenu = .standard
    public var subtitle: Ink = .standard
    /// A popover's inner padding; nil: today's.
    public var popoverPadding: CGFloat?
    public var popoverHeader: PopoverHeader = .standard
    /// A popover's progress track height; nil: today's 4.
    public var progressHeight: CGFloat?
    public var progressFill: ProgressFill = .standard

    public init() {}

    /// The look every key unset draws: today's.
    public static let standard = MenuLook()

    /// `appearance.menu.shadow`: the panel's drop, on the shared elevation scale. Every step fits in
    /// the band a native popover keeps for its shadow (``PopupStyle/shadowMargin``).
    public enum Shadow: String, Sendable, CaseIterable {
        case standard, none, subtle, strong

        /// The drop; nil draws none.
        @MainActor public var elevation: Elevation? {
            switch self {
            case .standard: PopupStyle.elevation2
            case .none: nil
            case .subtle: PopupStyle.elevation1
            // The standard drop's geometry, darker: it stays inside the native shadow band.
            case .strong: Elevation(offset: 2, blur: 6, alpha: 0.28)
            }
        }
    }

    /// A secondary ink (the shortcut column, a section label, a row's second line): today's, or muted
    /// (the text at ``mutedShare``; the native tertiary ink).
    public enum Ink: String, Sendable, CaseIterable { case standard, muted }

    /// The text share a muted secondary ink draws in on a page.
    public static let mutedShare: CGFloat = 0.45

    /// `appearance.menu.separator`: today's line, a line at half its ink, or only the gap.
    public enum Separator: String, Sendable, CaseIterable {
        case standard, subtle, none

        /// The share of the separator's ink a line draws in.
        public var inkShare: CGFloat {
            switch self {
            case .standard: 1
            case .subtle: 0.5
            case .none: 0
            }
        }
    }

    /// `appearance.menu.destructiveInk`: a destructive row in the danger red (today) or its own ink.
    public enum DestructiveInk: String, Sendable, CaseIterable { case standard, plain }

    /// `appearance.menu.submenu`: beside its row with today's gap, or flush against the menu's edge
    /// with its first row level with the row that opened it.
    public enum Submenu: String, Sendable, CaseIterable { case standard, flush }

    /// `appearance.popover.header`: today's header, or body type at emphasis weight in the primary ink.
    public enum PopoverHeader: String, Sendable, CaseIterable { case standard, strong }

    /// `appearance.popover.progressFill`: the accent (today), the secondary ink or the primary ink.
    public enum ProgressFill: String, Sendable, CaseIterable { case standard, muted, strong }

    /// The panel's inner padding and the hover fill's inset, as the native menus draw them.
    public var resolvedPadding: CGFloat { padding ?? MenuMetrics.highlightInset }

    // MARK: Pages

    /// The look tokens pages read, only for the keys that are set: an unset key sends nothing, so a
    /// look's own stylesheet value, else today's, stays. Colors come from the page's own ink
    /// (`currentColor`), never a literal, except a fill the file names.
    @MainActor public var webVariables: [String: String] {
        var tokens: [String: String] = [:]
        func px(_ name: String, _ value: CGFloat?) {
            if let value { tokens[name] = "\(Self.number(value))px" }
        }
        func share(_ value: CGFloat) -> String { "color-mix(in srgb, currentColor \(Self.number(value * 100))%, transparent)" }
        let muted = share(Self.mutedShare)
        px("--menu-radius", cornerRadius)
        if let borderOpacity { tokens["--menu-border"] = share(borderOpacity) }
        if shadow != .standard {
            tokens["--menu-shadow"] = shadow.elevation.map {
                "0 \(Self.number($0.offset))px \(Self.number($0.blur))px rgba(0, 0, 0, \(Self.number($0.alpha)))"
            } ?? "none"
        }
        if let fill { tokens["--menu-fill"] = WebTheme.css(fill) }
        px("--menu-padding", padding)
        px("--menu-hover-radius", highlightRadius)
        px("--menu-row-height", rowHeight)
        if shortcuts == .muted { tokens["--menu-shortcut-color"] = muted }
        if sectionLabel == .muted {
            tokens["--menu-label-color"] = muted
            tokens["--menu-label-weight"] = "var(--weight-regular, 400)"
        }
        switch separator {
        case .standard: break
        case .subtle: tokens["--menu-separator"] = share(0.06)
        case .none: tokens["--menu-separator"] = "transparent"
        }
        if destructiveInk == .plain { tokens["--menu-destructive"] = "currentColor" }
        if submenu == .flush {
            // The submenu's panel against the menu's edge (its row is the padding in from that edge),
            // its first row level with the row that opened it (its own padding above that row).
            tokens["--menu-submenu-offset"] = "\(Self.number(resolvedPadding))px"
            tokens["--menu-submenu-align-offset"] = "\(Self.number(-resolvedPadding))px"
        }
        if subtitle == .muted { tokens["--menu-subtitle-color"] = muted }
        px("--popover-padding", popoverPadding)
        if popoverHeader == .strong {
            tokens["--popover-header-color"] = "currentColor"
            tokens["--popover-header-size"] = "var(--text-body, 13px)"
            tokens["--popover-header-weight"] = "var(--weight-emphasis, 600)"
        }
        px("--popover-progress-height", progressHeight)
        switch progressFill {
        case .standard: break
        case .muted: tokens["--popover-progress-fill"] = share(0.55)
        case .strong: tokens["--popover-progress-fill"] = "currentColor"
        }
        return tokens
    }

    /// A CSS number: no trailing `.0`, at most three decimals.
    static func number(_ value: CGFloat) -> String {
        let rounded = (Double(value) * 1000).rounded() / 1000
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }
}

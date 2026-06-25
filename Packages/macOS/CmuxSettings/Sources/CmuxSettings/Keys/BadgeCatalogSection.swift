import Foundation

/// Settings under the dotted-id prefix `badge.*`.
///
/// Controls the optional scroll-fixed badge watermark rendered inside every
/// terminal surface, similar to iTerm2's session badge. The badge identifies
/// which workspace and tab a surface belongs to and stays fixed regardless of
/// scrollback volume or scroll position.
///
/// All keys are ``JSONKey``: they are read from and written to
/// `~/.config/cmux/cmux.json` directly through a ``JSONConfigStore`` and
/// live-reload when the file changes. The badge is off by default
/// (``enabled`` is `false`), so existing users see no change until they opt in.
public struct BadgeCatalogSection: SettingCatalogSection {
    /// Minimum allowed badge font size, in points.
    public static let fontSizeMinimum = 8.0
    /// Maximum allowed badge font size, in points.
    public static let fontSizeMaximum = 96.0
    /// Default badge font size, in points.
    public static let fontSizeDefault = 28.0
    /// Default badge opacity, from `0` (invisible) to `1` (opaque).
    public static let opacityDefault = 0.18

    /// Whether the terminal badge watermark is shown. Off by default.
    public let enabled = JSONKey<Bool>(
        id: "badge.enabled",
        defaultValue: false
    )

    /// The badge text template. Free-form text with `{workspace}`, `{tab}`,
    /// `{tabIndex}`, and `{workspaceIndex}` placeholders substituted per
    /// surface; see ``TerminalBadgeTemplate``.
    public let template = JSONKey<String>(
        id: "badge.template",
        defaultValue: TerminalBadgeTemplate.defaultRawValue
    )

    /// Which corner (or center) of the terminal surface the badge anchors to.
    public let position = JSONKey<BadgePosition>(
        id: "badge.position",
        defaultValue: .topTrailing
    )

    /// Badge opacity, from `0` (invisible) to `1` (opaque).
    public let opacity = JSONKey<Double>(
        id: "badge.opacity",
        defaultValue: BadgeCatalogSection.opacityDefault
    )

    /// Badge text color as a `#RRGGBB` hex string. Empty means follow the
    /// terminal's foreground/label color.
    public let color = JSONKey<String>(
        id: "badge.color",
        defaultValue: ""
    )

    /// Badge font size, in points. Clamped to
    /// ``fontSizeMinimum``...``fontSizeMaximum`` when applied.
    public let fontSize = JSONKey<Double>(
        id: "badge.fontSize",
        defaultValue: BadgeCatalogSection.fontSizeDefault
    )

    /// Creates the badge settings section with its default keys.
    public init() {}
}

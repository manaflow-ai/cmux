/// cmux.json `layout.stripScrollbar`: the thin scrollbar under the column
/// strip (plans/cmux-next/dock-column.md, B4).
public nonisolated enum StripScrollbarMode: String, Hashable, Sendable, CaseIterable {
    /// Follows the macOS "Show scroll bars" setting (the default): `auto` for overlay scrollers,
    /// `always` for legacy ones ("Always", or "Automatically" with a mouse), live on a change.
    case system
    /// Fades in while the strip scrolls or the pointer is over it, then out.
    case auto
    /// Shows whenever the columns do not fit.
    case always
    /// Never shows.
    case off

    /// Parses the cmux.json value; `true`/`false` and "on"/"never" are accepted too.
    public init?(configValue: String) {
        switch configValue.lowercased() {
        case "system": self = .system
        case "auto", "true": self = .auto
        case "always", "on": self = .always
        case "off", "never", "false", "none": self = .off
        default: return nil
        }
    }

    /// The palette toggle: off turns it on (following the system), anything else turns it off.
    public var toggled: StripScrollbarMode { self == .off ? .system : .off }

    /// The mode the scrollbar applies: `system` resolved against the macOS scroller style
    /// (`legacyScrollers`: `NSScroller.preferredScrollerStyle == .legacy`); others as chosen.
    public func resolved(legacyScrollers: Bool) -> StripScrollbarMode {
        guard self == .system else { return self }
        return legacyScrollers ? .always : .auto
    }
}

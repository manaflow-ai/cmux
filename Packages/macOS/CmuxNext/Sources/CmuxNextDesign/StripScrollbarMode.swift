/// cmux.json `layout.stripScrollbar`: the thin scrollbar under the column
/// strip (plans/cmux-next/dock-column.md, B4).
public nonisolated enum StripScrollbarMode: String, Hashable, Sendable, CaseIterable {
    /// Fades in while the strip scrolls or the pointer is over it, then out.
    case auto
    /// Shows whenever the columns do not fit.
    case always
    /// Never shows.
    case off

    /// Parses the cmux.json value; `true`/`false` and "on"/"never" are accepted too.
    public init?(configValue: String) {
        switch configValue.lowercased() {
        case "auto", "true": self = .auto
        case "always", "on": self = .always
        case "off", "never", "false", "none": self = .off
        default: return nil
        }
    }

    /// The palette toggle: off turns it on (auto), anything else turns it off.
    public var toggled: StripScrollbarMode { self == .off ? .auto : .off }
}

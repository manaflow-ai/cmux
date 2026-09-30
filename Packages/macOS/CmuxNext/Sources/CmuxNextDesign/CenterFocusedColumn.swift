/// niri `layout { center-focused-column "never" | "always" | "on-overflow" }`.
/// cmux.json: `layout.centerFocusedColumn`. See plans/cmux-next/niri.md.
public nonisolated enum CenterFocusedColumn: String, Hashable, Sendable, CaseIterable {
    /// Scroll the least amount that makes the focused column fully visible
    /// (niri default).
    case never
    /// Always center the focused column (clamped at the strip ends).
    case always
    /// Center only when the focused column and the column focus came from do
    /// not fit on screen together; otherwise scroll the least amount.
    case onOverflow = "on-overflow"

    /// Parses the cmux.json value; also accepts niri's spelling variants.
    public init?(configValue: String) {
        switch configValue.lowercased() {
        case "never": self = .never
        case "always": self = .always
        case "on-overflow", "onoverflow", "on_overflow": self = .onOverflow
        default: return nil
        }
    }
}

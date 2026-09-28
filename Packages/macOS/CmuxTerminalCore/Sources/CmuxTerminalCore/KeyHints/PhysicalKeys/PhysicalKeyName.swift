/// A key that a tooltip names in words rather than by its glyph alone, so
/// the app can show a localized name.
public enum PhysicalKeyName: Sendable, Hashable {
    case control
    case option
    case shift
    case command
    case capsLock
    case escape
}

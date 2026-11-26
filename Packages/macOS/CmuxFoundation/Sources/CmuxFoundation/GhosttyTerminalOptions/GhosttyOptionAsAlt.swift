/// Ghostty's `macos-option-as-alt` values. The raw value is the config spelling.
///
/// ``automatic`` is the unset state: Ghostty then treats Option as Alt only on
/// the U.S. keyboard layouts. Writing it stores an empty value, which resets the
/// option to that default even when an earlier config file set it.
public enum GhosttyOptionAsAlt: String, CaseIterable, Sendable {
    case automatic = ""
    case off = "false"
    case left
    case right
    case both = "true"
}

/// Outcome of asking ``AccessibilityWindowCaching`` to answer an
/// `NSAccessibility` attribute query.
///
/// `handled` carries the cached value the caller should return directly;
/// `passthrough` means the cache does not own this attribute and AppKit must
/// remain authoritative.
public enum AccessibilityWindowResolution {
    /// The cache does not handle this attribute; fall through to AppKit.
    case passthrough
    /// The cache answered the attribute with this value (which may be nil).
    case handled(Any?)
}

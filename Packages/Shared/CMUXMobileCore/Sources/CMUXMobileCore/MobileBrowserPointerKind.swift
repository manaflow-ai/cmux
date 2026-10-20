/// Pointer action replayed against the Mac browser.
public enum MobileBrowserPointerKind: String, Codable, Equatable, Sendable {
    /// A complete press-and-release click.
    case click
    /// Pointer button press.
    case down
    /// Pointer button release.
    case up
}

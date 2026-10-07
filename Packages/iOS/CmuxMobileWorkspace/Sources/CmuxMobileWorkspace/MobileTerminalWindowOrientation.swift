import Foundation

/// The window interface orientation, used to resolve the landscape camera edge.
public enum MobileTerminalWindowOrientation: Equatable, Sendable {
    /// Portrait, home indicator at the bottom.
    case portrait
    /// Portrait, upside down.
    case portraitUpsideDown
    /// Landscape, device rotated left (home indicator on the right).
    case landscapeLeft
    /// Landscape, device rotated right (home indicator on the left).
    case landscapeRight
    /// The orientation could not be determined.
    case unknown
}

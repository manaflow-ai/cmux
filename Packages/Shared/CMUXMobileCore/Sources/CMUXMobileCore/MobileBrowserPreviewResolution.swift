/// The requested fidelity for a mirrored Mac browser snapshot.
public enum MobileBrowserPreviewResolution: String, Codable, Equatable, Sendable {
    /// A compact card image whose longest edge targets approximately 600 pixels.
    case preview
    /// A larger image requested while the mirrored browser is open full-screen.
    case full
}

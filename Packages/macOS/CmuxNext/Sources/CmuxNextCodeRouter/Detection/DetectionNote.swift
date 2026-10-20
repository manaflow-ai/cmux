import Foundation

/// A credential type the row names in words, which the UI that shows the
/// row localizes (``ProviderDetection/detail`` is a name or an address and
/// is shown as is).
public enum DetectionNote: String, Sendable, Equatable, Hashable, Encodable {
    /// An API key Claude Code's `/login` saved in `.claude.json`.
    case savedAPIKey = "saved_api_key"
}

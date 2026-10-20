import Foundation

/// Localizable string reference used by in-process sidebar providers.
public struct CmuxSidebarProviderLocalizedText: Codable, Equatable, Hashable, Sendable {
    /// String catalog key.
    public var key: String

    /// English fallback shown when localization is unavailable.
    public var defaultValue: String

    /// Creates a localizable sidebar-provider string.
    public init(key: String, defaultValue: String) {
        self.key = key
        self.defaultValue = defaultValue
    }
}

import Foundation

/// Icon model for a provider row.
public struct CmuxSidebarProviderIcon: Codable, Equatable, Sendable {
    /// Optional SF Symbols name.
    public var systemImageName: String?
    /// Optional short text fallback.
    public var text: String?
    /// Foreground color as a CSS-style hex string.
    public var foregroundColorHex: String?
    /// Background color as a CSS-style hex string.
    public var backgroundColorHex: String?
    /// Background shape.
    public var shape: CmuxSidebarProviderIconShape

    /// Creates a provider row icon.
    public init(
        systemImageName: String? = nil,
        text: String? = nil,
        foregroundColorHex: String? = nil,
        backgroundColorHex: String? = nil,
        shape: CmuxSidebarProviderIconShape = .circle
    ) {
        self.systemImageName = systemImageName
        self.text = text
        self.foregroundColorHex = foregroundColorHex
        self.backgroundColorHex = backgroundColorHex
        self.shape = shape
    }
}

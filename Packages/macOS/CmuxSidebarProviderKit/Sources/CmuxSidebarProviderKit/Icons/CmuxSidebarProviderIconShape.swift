import Foundation

/// Shape used behind a provider row icon.
public enum CmuxSidebarProviderIconShape: String, Codable, Equatable, Sendable {
    /// Circular icon background.
    case circle
    /// Rounded-rectangle icon background.
    case roundedRectangle = "rounded-rectangle"
}

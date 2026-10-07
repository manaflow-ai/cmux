import Foundation

/// One browser profile in the Rooms & Profiles section.
public struct SettingsBrowserProfileRow: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// One of the 9 color names, or nil.
    public let color: String?
    /// An SF Symbol name or one emoji, or nil.
    public let icon: String?
    public let isDefault: Bool
    /// Where an imported profile came from ("Google Chrome · Work"), or nil.
    public let source: String?

    public init(id: String, name: String, color: String? = nil, icon: String? = nil, isDefault: Bool = false, source: String? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.icon = icon
        self.isDefault = isDefault
        self.source = source
    }
}

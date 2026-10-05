import Foundation

/// A host-owned project label with an extensible classification dimension.
public struct CmuxSidebarContextTag: Codable, Equatable, Identifiable, Sendable {
    /// Stable semantic tag ID, reused across analyses and rejections.
    public var id: String
    /// Human-readable label.
    public var label: String
    /// Generic category, such as project, topic, or technology.
    public var dimension: String
    /// Whether the user or an analyzer selected this tag.
    public var origin: CmuxSidebarContextTagOrigin
    /// Declared source of the label, without conversation content.
    public var source: String

    /// Creates a project-context tag.
    /// - Parameters:
    ///   - id: Stable semantic tag identifier.
    ///   - label: Display label.
    ///   - dimension: Extensible classification category.
    ///   - origin: Manual or automatic provenance.
    ///   - source: Declared provenance label.
    public init(id: String, label: String, dimension: String, origin: CmuxSidebarContextTagOrigin, source: String) {
        self.id = id
        self.label = label
        self.dimension = dimension
        self.origin = origin
        self.source = source
    }
}

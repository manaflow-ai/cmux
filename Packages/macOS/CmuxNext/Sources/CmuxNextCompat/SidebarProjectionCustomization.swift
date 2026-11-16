import Foundation

/// Bounded projection overrides read from cmux-next.json. The document remains
/// the persistence owner; these values only select what the native view draws.
public nonisolated struct SidebarProjectionCustomization: Hashable, Sendable {
    public struct Workspace: Hashable, Sendable {
        public var hidden: Bool
        public var group: String?
        public var order: Int?

        public init(hidden: Bool = false, group: String? = nil, order: Int? = nil) {
            self.hidden = hidden
            self.group = group
            self.order = order
        }
    }

    public var hiddenSections: [String]
    public var sectionOrder: [String]
    public var workspaces: [String: Workspace]
    /// False when the settings held a malformed value (Rust's `complete`).
    /// The sidebar then keeps its last good projection, with the diagnostic in
    /// Settings, until a saved fix makes the value whole again.
    public var isComplete: Bool

    public init(hiddenSections: [String] = [], sectionOrder: [String] = [], workspaces: [String: Workspace] = [:],
                isComplete: Bool = true) {
        self.hiddenSections = hiddenSections
        self.sectionOrder = sectionOrder
        self.workspaces = workspaces
        self.isComplete = isComplete
    }

    /// Whether any section or workspace is hidden.
    public var hidesAnything: Bool { !hiddenSections.isEmpty || workspaces.values.contains(where: \.hidden) }

    public static let defaults = Self()
}

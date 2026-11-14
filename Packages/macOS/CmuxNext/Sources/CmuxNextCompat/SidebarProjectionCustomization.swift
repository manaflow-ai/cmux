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

    public init(hiddenSections: [String] = [], sectionOrder: [String] = [], workspaces: [String: Workspace] = [:]) {
        self.hiddenSections = hiddenSections
        self.sectionOrder = sectionOrder
        self.workspaces = workspaces
    }

    public static let defaults = Self()
}

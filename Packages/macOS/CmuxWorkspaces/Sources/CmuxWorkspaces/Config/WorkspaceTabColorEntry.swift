import Foundation

/// A name + hex color palette entry for workspace tab colors. The pure value
/// half of the workspace tab-color domain, consumed by ``WorkspaceTabColorSettings``
/// and the app-side rendering extension.
public struct WorkspaceTabColorEntry: Equatable, Identifiable, Sendable {
    public let name: String
    public let hex: String

    public var id: String { name }

    public init(name: String, hex: String) {
        self.name = name
        self.hex = hex
    }
}

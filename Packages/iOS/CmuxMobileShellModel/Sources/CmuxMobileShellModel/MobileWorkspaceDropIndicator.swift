public import CoreGraphics
import Foundation

/// Geometry and styling for a workspace drop indicator.
public struct MobileWorkspaceDropIndicator: Equatable, Sendable {
    /// The insertion boundary or highlighted header's vertical center.
    public let y: CGFloat
    /// Whether an insertion line uses the member-row indentation.
    public let indented: Bool
    /// The visual indicator treatment.
    public let kind: MobileWorkspaceDropIndicatorKind

    /// Creates a drop indicator specification.
    /// - Parameters:
    ///   - y: The vertical position in list coordinates.
    ///   - indented: Whether the line begins at the group-member inset.
    ///   - kind: The indicator treatment.
    public init(y: CGFloat, indented: Bool, kind: MobileWorkspaceDropIndicatorKind) {
        self.y = y
        self.indented = indented
        self.kind = kind
    }
}

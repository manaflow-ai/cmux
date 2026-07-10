public import CoreGraphics
import Foundation

/// A rendered workspace-list row and its bounds in list coordinates.
public struct MobileWorkspaceDropRowFrame: Equatable, Sendable {
    /// The semantic row identity.
    public let kind: MobileWorkspaceDropRowKind
    /// The row bounds in the list's named coordinate space.
    public let frame: CGRect

    /// Creates a row-frame snapshot.
    /// - Parameters:
    ///   - kind: The semantic row identity.
    ///   - frame: The row bounds in list coordinates.
    public init(kind: MobileWorkspaceDropRowKind, frame: CGRect) {
        self.kind = kind
        self.frame = frame
    }
}

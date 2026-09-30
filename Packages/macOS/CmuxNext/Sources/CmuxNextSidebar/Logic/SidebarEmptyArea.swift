public import CoreGraphics
import Foundation

/// Where a double-click on empty sidebar space makes a new workspace: the
/// end of a machine section, or the end of the expanded group whose empty
/// part is under the pointer.
public nonisolated struct SidebarEmptyAreaTarget: Hashable, Sendable {
    public var section: SectionID
    public var group: GroupID?

    public init(section: SectionID, group: GroupID? = nil) {
        self.section = section
        self.group = group
    }
}

extension SidebarLayout {
    /// The new-workspace target for a double-click at `y`, or nil on a row.
    public func emptyAreaTarget(at y: CGFloat, metrics: SidebarLayoutMetrics) -> SidebarEmptyAreaTarget? {
        nil
    }
}

import SwiftUI

/// Accumulates every ``SidebarTapTarget`` in the rendered sidebar.
public struct SidebarTapTargetsKey: PreferenceKey {
    /// No targets until the render tree reports some.
    public static let defaultValue: [SidebarTapTarget] = []

    /// Concatenates targets from sibling subtrees.
    public static func reduce(value: inout [SidebarTapTarget], nextValue: () -> [SidebarTapTarget]) {
        value.append(contentsOf: nextValue())
    }
}

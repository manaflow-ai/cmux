public import SwiftUI

/// Collects each workspace row's bounds anchor, keyed by the row's workspace
/// `UUID`, so the sidebar can resolve drop targets from on-screen geometry.
///
/// Rows publish their anchor through ``SidebarWorkspaceFrameAnchorModifier``;
/// the sidebar reads the merged dictionary via `overlayPreferenceValue`. The
/// reducer keeps the last value for a duplicate key, matching the original
/// ContentView definition.
public struct SidebarWorkspaceRowFramePreferenceKey: PreferenceKey {
    public static let defaultValue: [UUID: Anchor<CGRect>] = [:]

    public static func reduce(
        value: inout [UUID: Anchor<CGRect>],
        nextValue: () -> [UUID: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, next in next }
    }
}

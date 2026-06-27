import Foundation

/// Strength of the tab-list scroll-edge fade mask in the left sidebar.
public enum SidebarScrollEdgeFadeStyle: String, CaseIterable, Sendable, SettingCodable {
    /// The default fade height and opacity ramp.
    case full

    /// A shorter, lighter fade that keeps more row content visible near edges.
    case subtle

    /// No top or bottom scroll-edge fade.
    case off
}

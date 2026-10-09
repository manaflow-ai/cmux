import CmuxSettings
import CmuxSidebar
import CoreGraphics
import Foundation

/// App-side resolution of the sidebar customization settings.
///
/// `CmuxSidebar` deliberately has no `CmuxSettings` dependency, so anything a
/// package type consumes (the peek policy, panel tint) is resolved here and
/// injected. Event-frequency reads (a toggle press, a drag start) go through
/// these statics directly; per-row values ride `SidebarTabItemSettingsSnapshot`
/// instead so the existing defaults-change pipeline re-renders them.
enum SidebarCustomizationSettings {
    /// The peek policy the current defaults describe.
    static func peekPolicy(defaults: UserDefaults = .standard) -> SidebarPeekPolicy {
        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let sidebar = SidebarCatalogSection()
        let preset = settings.value(for: sidebar.peekReveal)
        let enabled = !settings.value(for: sidebar.peekDisabled)
        switch preset {
        case .instant:
            // A wider strip pairs with the zero dwell: the pointer thrown at
            // the edge lands anywhere in it and the panel is already there.
            return SidebarPeekPolicy(
                dwell: .zero,
                grace: .milliseconds(250),
                edgeWidth: 20,
                dismissesOnWorkspaceActivation: true,
                isEnabled: enabled
            )
        case .quick:
            return SidebarPeekPolicy(
                dwell: .milliseconds(120),
                grace: .milliseconds(250),
                edgeWidth: 14,
                dismissesOnWorkspaceActivation: true,
                isEnabled: enabled
            )
        case .relaxed:
            return SidebarPeekPolicy(
                dwell: .milliseconds(280),
                grace: .milliseconds(350),
                edgeWidth: 10,
                dismissesOnWorkspaceActivation: true,
                isEnabled: enabled
            )
        }
    }

    static func dragSwitchDisabled(defaults: UserDefaults = .standard) -> Bool {
        UserDefaultsSettingsClient(defaults: defaults)
            .value(for: SidebarCatalogSection().dragSwitchDisabled)
    }
}

extension SidebarRowDensity {
    /// Vertical padding above and below a workspace row's content.
    var rowVerticalPadding: CGFloat {
        switch self {
        case .compact: 4
        case .cozy: 8
        case .spacious: 12
        }
    }
}

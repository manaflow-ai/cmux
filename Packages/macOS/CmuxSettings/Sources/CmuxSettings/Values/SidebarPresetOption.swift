import Foundation

/// User-selectable preset bundle for the sidebar's appearance.
/// Selecting a preset writes a coordinated set of material/blend/state/
/// tint values; choosing `custom` keeps whatever the user has already
/// dialed in.
public enum SidebarPresetOption: String, CaseIterable, Sendable, SettingCodable {
    case nativeSidebar
    case nativeTitlebar
    case translucent
    case opaqueDark
    case opaqueLight
    case custom
}

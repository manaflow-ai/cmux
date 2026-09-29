#if DEBUG
import CmuxSettings
import SwiftUI

/// Debug menu submenu that switches `rightSidebar.toggleButton` live, with a
/// checkmark on the active placement.
struct RightSidebarToggleButtonDebugMenu: View {
    @AppStorage(SettingCatalog().rightSidebar.toggleButton.userDefaultsKey)
    private var placementRawValue = SettingCatalog().rightSidebar.toggleButton.defaultValue.rawValue

    var body: some View {
        Picker(
            String(localized: "debug.menu.rightSidebarToggleButton", defaultValue: "Right Sidebar Button"),
            selection: $placementRawValue
        ) {
            ForEach(RightSidebarToggleButtonPlacement.allCases, id: \.self) { placement in
                Text(placement.localizedTitle).tag(placement.rawValue)
            }
        }
    }
}
#endif

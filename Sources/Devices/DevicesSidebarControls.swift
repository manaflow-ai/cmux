import CmuxSettingsUI
import SwiftUI

/// Native menu content presented from the sidebar's computer button.
/// Receives values and actions rather than holding an observable store.
struct DevicesSidebarControls: View {
    let discoveryEnabled: Bool
    let incomingAccessEnabled: Bool
    let discoveryManaged: Bool
    let incomingAccessManaged: Bool
    let setDiscovery: (Bool) -> Void
    let setIncomingAccess: (Bool) -> Void

    var body: some View {
        Group {
            ComputerAccessMenuItems(
                discoveryEnabled: discoveryEnabled,
                incomingAccessEnabled: incomingAccessEnabled,
                discoveryManaged: discoveryManaged,
                incomingAccessManaged: incomingAccessManaged,
                identifierPrefix: "Devices",
                setDiscovery: setDiscovery,
                setIncomingAccess: setIncomingAccess
            )
        }
    }
}

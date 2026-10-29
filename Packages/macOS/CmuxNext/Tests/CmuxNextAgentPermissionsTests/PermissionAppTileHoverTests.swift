import AppKit
@testable import CmuxNextAgentPermissions
import Testing

/// The permission card floats over System Settings with cmux in the background,
/// so the app tile to drag keeps its hover there (`.activeAlways`, bounded by the card showing),
/// where an `.activeForHover` area would hear nothing.
@MainActor @Suite struct PermissionAppTileHoverTests {
    @Test func theAppTileHoversOverSystemSettings() {
        let tile = PermissionAppTile(appURL: URL(fileURLWithPath: "/Applications/cmux.app"), icon: nil)
        tile.updateTrackingAreas()
        #expect(tile.trackingAreas.contains { $0.options.contains(.activeAlways) },
                "the tile hears no enter or exit while System Settings is the active app")
    }
}

import CmuxNextActions
import CmuxNextDevices
@testable import CmuxNextMacScreen
import CmuxNextPalette
import CmuxNextWakeups
import Foundation
import Testing

/// Screen Sharing in the palette: found by what a person types ("screen share", "vnc", "remote desktop"),
/// and one row per device ("Screen Sharing: Studio") that opens that device's screen in one step.
@MainActor @Suite struct MacScreenPaletteRowsTests {
    private let mac = HubDevice(id: "0b6c1a2e-3d4f-4a5b-8c9d-aabbccddeeff", name: "Studio", platform: .macos, online: true)

    @Test func eachDeviceRowOpensThatDevicesScreenAsAPerson() throws {
        let phone = HubDevice(id: "1b6c1a2e-3d4f-4a5b-8c9d-aabbccddeeff", name: "iPhone", platform: .ios, macScreenShared: true)
        let unnamed = HubDevice(id: "2b6c1a2e-3d4f-4a5b-8c9d-aabbccddeeff", name: "")
        var ran: [ActionInvocation] = []
        let rows = MacScreenPages.paletteRows(devices: [mac, phone, unnamed], actionTitle: "Screen Sharing") { ran.append($0) }
        #expect(rows.map(\.title) == ["Screen Sharing: Studio", "Screen Sharing: iPhone"])
        #expect(rows.map(\.symbol) == ["display", "iphone"])
        let row = try #require(rows.first)
        #expect(row.keywords.contains("Studio"))
        #expect(row.keywords.contains("vnc"))
        #expect(row.frecencyKey == "macScreen.devices:\(mac.id)")
        guard case let .perform(run) = row.primary.effect else {
            Issue.record("a device row runs, it does not open a page")
            return
        }
        run()
        #expect(ran.count == 1)
        #expect(ran.first?["device"]?.stringValue == mac.id)
        #expect(ran.first?.origin == .user)
    }

    @Test func noActionTitleListsNoRows() {
        #expect(MacScreenPages.paletteRows(devices: [mac], actionTitle: nil) { _ in }.isEmpty)
    }

    @Test func signedOutListsNoDevices() {
        let file = FileManager.default.temporaryDirectory.appending(path: "screen-palette-\(UUID().uuidString)/store.json")
        let pages = MacScreenPages(store: MacScreenStore(file: file, removeLinkPairings: {}), work: BackgroundWork())
        #expect(pages.viewableDevices.isEmpty)
    }

    @Test func screenSharingIsFoundByTheWordsPeopleType() throws {
        let registry = ActionRegistry.standard()
        let open = try #require(registry.descriptor(for: "macScreen.open"))
        for word in ["screen share", "share screen", "remote desktop", "vnc", "view"] {
            #expect(open.keywords.contains(word), "\(word)")
        }
        #expect(open.paletteTier == .daily)
        // This Mac's sharing session (stop it, revoke its viewer) sits with Share This Mac, not with tabs.
        for id: ActionID in ["macScreen.stopSharing", "macScreen.revokeViewer", "macScreen.shareThisMac", "macScreen.stopSharingThisMac"] {
            #expect(registry.descriptor(for: id)?.category == .remote, "\(id)")
        }
    }
}

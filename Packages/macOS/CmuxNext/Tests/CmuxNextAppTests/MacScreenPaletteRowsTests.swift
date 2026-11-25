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
        #expect(rows.map(\.symbol) == ["desktopcomputer", "iphone"])
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

    /// A Linux desktop draws its own glyph, not a Mac's (Leo 2026-11-16: "i dont see windows nor linux"); a Windows PC,
    /// which this Mac cannot view yet, gets no Connect row (Your Devices lists it as "Can’t view yet").
    @Test func linuxAndWindowsRowsDrawTheirPlatform() {
        let linux = HubDevice(id: "3b6c1a2e-3d4f-4a5b-8c9d-aabbccddeeff", name: "Box", platform: .linux, online: true)
        let windows = HubDevice(id: "4b6c1a2e-3d4f-4a5b-8c9d-aabbccddeeff", name: "PC", platform: .windows, online: true)
        let rows = MacScreenPages.paletteRows(devices: [linux, windows], actionTitle: "Screen Sharing") { _ in }
        #expect(rows.map(\.symbol) == ["server.rack"])
    }

    @Test func noActionTitleListsNoRows() {
        #expect(MacScreenPages.paletteRows(devices: [mac], actionTitle: nil) { _ in }.isEmpty)
    }

    @Test func signedOutListsNoDevices() {
        let file = FileManager.default.temporaryDirectory.appending(path: "screen-palette-\(UUID().uuidString)/store.json")
        let pages = MacScreenPages(store: MacScreenStore(file: file, removeLinkPairings: {}), work: BackgroundWork())
        #expect(pages.viewableDevices.isEmpty)
    }
    // The catalog's keywords, tier and categories are pinned in Rust (cmux-action-catalog
    // tests/screen_sharing_palette.rs): the app reads them from the published FFI, re-pinned after merge.
}

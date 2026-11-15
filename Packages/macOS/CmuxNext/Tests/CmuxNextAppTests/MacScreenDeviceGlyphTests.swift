import AppKit
import CmuxNextDevices
@testable import CmuxNextMacScreen
import CmuxNextTestSupport
import CmuxNextWakeups
import Foundation
import Testing

/// Screen Sharing's Your Devices draws each device as what it is (a MacBook, a Mac mini), from the
/// kind its device-hub record names, and the old iPhone or desktop icon when it never said (Leo,
/// 2026-11-14: "nicer icons ... across all the remote related areas").
@MainActor @Suite(.serialized, .closesItsWindows)
struct MacScreenDeviceGlyphTests {
    private func row(_ name: String, platform: DevicePlatform, kind: String?) -> MacScreenHomeSnapshot.Device {
        MacScreenHomeSnapshot.Device(HubDevice(id: name, name: name, platform: platform, macScreenShared: true, kind: kind, online: true),
                                     access: MacScreenAccess(.ask))
    }

    /// Every MacScreenGlyph under `root`, depth first.
    private func glyphs(under root: NSView) -> [String] {
        root.subviews.flatMap { view in ((view as? MacScreenGlyph).map { [$0.symbol] } ?? []) + glyphs(under: view) }
    }

    @Test func aRowTakesItsKindsSymbolAndFallsBackToItsPlatformsIcon() {
        #expect(row("Laptop", platform: .macos, kind: "macbook").glyph == "macbook.gen2")
        #expect(row("Mini", platform: .macos, kind: "mac-mini").glyph == "macmini")
        #expect(row("Rack", platform: .macos, kind: "linux-server").glyph == "server.rack")
        #expect(row("Phone", platform: .ios, kind: "iphone").glyph == "iphone")
        // Never said, said generic, or a kind this build does not know: the icon it drew before.
        #expect(row("Old", platform: .macos, kind: nil).glyph == "desktopcomputer")
        #expect(row("Generic", platform: .macos, kind: "generic").glyph == "desktopcomputer")
        #expect(row("Newer", platform: .macos, kind: "vision-pro").glyph == "desktopcomputer")
        #expect(row("Old phone", platform: .ios, kind: nil).glyph == "iphone")
        // A symbol this macOS lacks never draws an empty glyph.
        var missing = row("Missing", platform: .macos, kind: nil)
        missing.symbol = "no.such.symbol.anywhere"
        #expect(missing.glyph == "desktopcomputer")
    }

    @Test func yourDevicesDrawsEachDevicesGlyph() {
        let home = MacScreenHomeView(host: MacScreenShareHost(work: BackgroundWork()), actions: MacScreenHomeActions())
        let section = home.yourDevices(.list([
            row("Laptop", platform: .macos, kind: "macbook"),
            row("Mini", platform: .macos, kind: "mac-mini"),
            row("Old", platform: .macos, kind: nil),
            row("Phone", platform: .ios, kind: nil),
        ]))
        #expect(glyphs(under: section) == ["macbook.gen2", "macmini", "desktopcomputer", "iphone"])
    }
}

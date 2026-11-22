import AppKit
@testable import CmuxNextApp
import CmuxNextSettings
import Foundation
import Testing

/// nxdog66-v1: debug.window_snapshot showed no refusal HUD after a refused
/// Cmd-W, so the check could not tell a missing notice from a missed
/// capture (the glass pill fades in and hides after 1.8 s). Every snapshot
/// reply now says what the HUD shows.
@MainActor
@Suite(.serialized) struct SnapshotRefusalHUDTests {
    @Test func theSnapshotReplySaysWhatTheHUDShows() throws {
        _ = NSApplication.shared
        let services = ActionBindingCoverageTests.boundServices()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let path = FileManager.default.temporaryDirectory.appending(path: "cmux-hud-\(UUID().uuidString).png").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let params: [String: JSONValue] = ["window": .string(String(window.windowNumber)), "path": .string(path)]

        let before = DebugWindowSnapshot.capture(params, services: services)
        #expect(before["refusal_hud"] == .null, "\(before)")
        services.refusalHUD.show(RefusalStrings.columnStaysDocked, in: window)
        let after = DebugWindowSnapshot.capture(params, services: services)
        #expect(after["refusal_hud"]?.stringValue == RefusalStrings.columnStaysDocked, "\(after)")
        #expect(after["refusal_hud_count"]?.intValue == 1)
    }
}

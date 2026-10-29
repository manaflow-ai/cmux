import AppKit
import CmuxNextActions
import CmuxNextDaemon
@testable import CmuxNextApp
import CmuxNextDesign
import Foundation
import Testing

/// Close Window closes with `NSWindow.closeWithoutButtonFlash()`, not `performClose(_:)` (whose close button flash
/// is a nested run loop of about 100 ms on the key turn, v2.2.4-opt; the proof of that is the live journey
/// diag-close-stall, handoff/v224-gate-triage.md: in a test process AppKit skips the flash, so a test of it passed
/// on the base and was removed). This pins the rule the new path keeps: a window with a sheet stays open.
@MainActor @Suite(.serialized) struct CloseWindowNoNestedLoopTests {
    private static func controller() throws -> (WindowController, AppServices) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"close-no-nested-loop","workspace_key":"cn1"}"#.utf8))
        let controller = WindowController(state: WindowState(record: record), services: services,
                                          frame: NSRect(x: 200, y: 200, width: 1100, height: 720))
        return (controller, services)
    }

    /// A sheet on the window (a folder picker, a confirmation) keeps it open, as AppKit's disabled close
    /// button does while a sheet is attached: the window never closes under its sheet.
    @Test func aWindowWithASheetStaysOpen() throws {
        let (controller, _) = try Self.controller()
        let window = try #require(controller.window)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        defer {
            if window.attachedSheet != nil { window.endSheet(sheet) }
            controller.teardown()
            window.close()
        }
        // AppKit attaches a sheet only to a window on screen: order it front and make it key first.
        window.makeKeyAndOrderFront(nil)
        window.beginSheet(sheet)
        try #require(window.attachedSheet === sheet, "AppKit attached no sheet in this test process")
        let closes = CloseCounter()
        let token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { _ in
            closes.add()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        controller.performClose(by: .script)

        #expect(closes.count == 0, "the window closed under its sheet")
    }
}

/// Window close notices counted on the main thread (AppKit posts `willClose` there, synchronously).
@MainActor
private final class CloseCounter: Sendable {
    private(set) var count = 0
    nonisolated func add() { MainActor.assumeIsolated { count += 1 } } // main-proof: NSWindow posts willClose on the main thread, delivered synchronously (queue: nil)
}

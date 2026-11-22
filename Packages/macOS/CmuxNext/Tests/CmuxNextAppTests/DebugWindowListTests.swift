import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// `debug.window_list` lists every app window, the ones AppKit makes for a
/// popover and a sheet too, and `debug.window_snapshot` renders any of them
/// by its id to a PNG.
@MainActor
@Suite(.serialized)
struct DebugWindowListTests {
    private func entry(_ list: JSONValue, id: Int) -> JSONValue? {
        guard case .array(let windows)? = list["windows"] else { return nil }
        return windows.first { $0["id"]?.intValue == id }
    }

    private func snapshot(_ window: NSWindow, services: AppServices, in directory: URL) throws -> (Int, Int) {
        let path = directory.appending(path: "\(window.windowNumber).png").path
        let result = DebugWindowSnapshot.capture(["window": .string(String(window.windowNumber)), "path": .string(path)], services: services)
        #expect(result["error"] == nil, "\(result)")
        let data = try #require(FileManager.default.contents(atPath: path))
        let rep = try #require(NSBitmapImageRep(data: data))
        return (rep.pixelsWide, rep.pixelsHigh)
    }

    @Test(.requiresGUISession) func aPopoverAndASheetAreListedAndSnapshotted() async throws {
        _ = NSApplication.shared
        let services = ActionBindingCoverageTests.boundServices()
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-window-list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let host = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 480, height: 320),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.install(kind: .settings, content: NSView(), scope: .app)
        host.orderBack(nil)
        defer { host.close() }
        let anchor = NSView(frame: NSRect(x: 40, y: 40, width: 20, height: 20))
        host.installedContent?.addSubview(anchor)

        // A popover shown from a view in the window.
        let popover = NSPopover()
        let popoverContent = NSViewController()
        popoverContent.view = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 90))
        popover.contentViewController = popoverContent
        popover.animates = false
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        defer { popover.close() }
        let popoverWindow = try #require(popoverContent.view.window)

        // A sheet over the window.
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        host.beginSheet(sheet, completionHandler: nil)
        defer { host.endSheet(sheet) }

        let list = DebugWindowList.list(services: services)
        let hostEntry = try #require(entry(list, id: host.windowNumber))
        #expect(hostEntry["kind"]?.stringValue == "settings")
        let popoverEntry = try #require(entry(list, id: popoverWindow.windowNumber), "the popover's window is listed")
        #expect(popoverEntry["kind"]?.stringValue == "popover")
        let sheetEntry = try #require(entry(list, id: sheet.windowNumber), "the sheet is listed")
        #expect(sheetEntry["kind"]?.stringValue == "sheet")
        #expect(sheetEntry["parent"]?.intValue == host.windowNumber)

        for window in [host, popoverWindow, sheet] {
            let (width, height) = try snapshot(window, services: services, in: directory)
            #expect(width > 0 && height > 0, "\(window)")
        }
    }
}

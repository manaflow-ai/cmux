import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Foundation
import Testing

/// Renders the right sidebar's sections, dark and light, at the right edge of a window into one
/// contact sheet, so a fleet run returns the sidebar's look as an artifact:
/// `Packages/macOS/CmuxNext/.build/right-sidebar-shots.png`. Each shot is also checked to draw.
@MainActor @Suite(.serialized) struct RightSidebarShotsTests {
    @Test func everySectionRendersToTheContactSheet() throws {
        _ = NSApplication.shared
        var shots: [(String, NSImage)] = []
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            for mode in RightSidebarMode.allCases {
                guard let image = try Self.shot(mode, appearance: appearance) else { continue }
                #expect(image.size.width > 0 && image.size.height > 0)
                shots.append(("\(mode.rawValue) \(name)", image))
            }
        }
        let sheet = AddServerShotsTests.contactSheet(shots)
        let out = AddServerShotsTests.packageRoot.appending(path: ".build/right-sidebar-shots.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AddServerShotsTests.png(sheet).write(to: out)
        print("right-sidebar-shots: wrote \(out.path)")
    }

    /// The window's right 560 pt with the sidebar at `mode`, on the appearance's window ground;
    /// nil when the mode has no section in this build.
    private static func shot(_ mode: RightSidebarMode, appearance: NSAppearance.Name) throws -> NSImage? {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let suite = "cmux-right-sidebar-shots-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        services.rightSidebarDefaults = defaults
        services.windows.ordersWindowsIn = false
        AppActions.bind(services)
        defer {
            for controller in services.windows.controllers { controller.window?.close() }
            defaults.removePersistentDomain(forName: suite)
        }
        let controller = try #require(services.windows.openWindow(workspaces: ["rs-shots"]))
        let window = try #require(controller.window)
        window.appearance = NSAppearance(named: appearance)
        window.setContentSize(NSSize(width: 1100, height: 640))
        guard services.registry.perform(mode.actionID, invocation: ActionInvocation(origin: .cli)) else { return nil }
        let root = controller.root
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        let crop = NSRect(x: root.bounds.width - 560, y: 0, width: 560, height: root.bounds.height)
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: crop))
        root.cacheDisplay(in: crop, to: rep)
        let image = NSImage(size: crop.size)
        image.lockFocus()
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: crop.size).fill()
        }
        rep.draw(in: NSRect(origin: .zero, size: crop.size), from: .zero, operation: .sourceOver, fraction: 1,
                 respectFlipped: true, hints: nil)
        image.unlockFocus()
        return image
    }
}

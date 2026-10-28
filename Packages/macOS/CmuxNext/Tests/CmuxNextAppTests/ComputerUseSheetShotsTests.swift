import AppKit
import CmuxNextCompat
import CmuxNextDesign
@testable import CmuxNextOnboarding
import Foundation
import Testing

/// Renders the Computer Use sheet in its main states, and the drag panel
/// docked under a System Settings window, into one contact sheet, so a fleet
/// run returns the look as an artifact:
/// `Packages/macOS/CmuxNext/.build/computer-use-sheet-shots.png`
/// (`cmux-ci run ... --artifact Packages/macOS/CmuxNext/.build/computer-use-sheet-shots.png`).
/// The window's own glass backdrop is not part of a view snapshot, so each
/// shot sits on a dark wallpaper-like fill.
@MainActor @Suite(.serialized) struct ComputerUseSheetShotsTests {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func sheetStatesRenderToTheContactSheet() async throws {
        _ = NSApplication.shared
        let states: [(String, ComputerUsePermissions)] = [
            ("1 nothing allowed", .none),
            ("2 Computer Use off", .off),
            ("3 Accessibility allowed", ComputerUsePermissions(accessibility: true, screenRecording: false)),
            ("4 both allowed", ComputerUsePermissions(accessibility: true, screenRecording: true)),
        ]
        var shots: [(String, NSImage)] = []
        for (name, permissions) in states {
            shots.append((name, try await Self.renderSheet(permissions)))
        }
        shots.append(("5 drag panel docked under System Settings", try Self.renderDock()))
        let sheet = AddServerShotsTests.contactSheet(shots)
        let out = Self.packageRoot.appending(path: ".build/computer-use-sheet-shots.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AddServerShotsTests.png(sheet).write(to: out)
        print("computer-use-sheet-shots: wrote \(out.path)")
    }

    static func renderSheet(_ permissions: ComputerUsePermissions) async throws -> NSImage {
        let services = MockOnboardingServices()
        let source = MockComputerUsePermissionSource(current: permissions)
        services.computerUseSource = source
        let model = OnboardingModel(services: services, step: .computerUse)
        let controller = OnboardingWindowController(model: model)
        let window = try #require(controller.window)
        window.appearance = NSAppearance(named: .darkAqua)
        model.computerUse.start()
        for await value in ObservationStream({ model.computerUse.permissions }) where value == permissions { break }
        let content = try #require(window.contentView)
        Self.renderAll(in: content)
        content.layoutSubtreeIfNeeded()
        let image = try snapshot(content, backdrop: NSColor(calibratedRed: 0.17, green: 0.16, blue: 0.15, alpha: 1))
        model.finish(completed: false)
        return image
    }

    /// Re-renders every render-loop view now (their loops run on the next turn).
    private static func renderAll(in view: NSView) {
        (view as? ComputerUseStepView)?.render()
        (view as? OnboardingFooter)?.render()
        view.subviews.forEach(renderAll)
    }

    /// A gray stand-in for the System Settings window with the real drag panel placed by `HelperPanelPlacement`.
    static func renderDock() throws -> NSImage {
        let panel = HelperDragPanel(appURL: URL(fileURLWithPath: "/Applications/cmux Computer Use.app")) {}
        panel.appearance = NSAppearance(named: .darkAqua)
        let panelView = try #require(panel.contentView)
        panelView.layoutSubtreeIfNeeded()
        let panelImage = try snapshot(panelView, backdrop: nil)
        let canvas = NSRect(x: 0, y: 0, width: 760, height: 520)
        let settings = NSRect(x: 60, y: 120, width: 640, height: 380)
        let origin = HelperPanelPlacement().origin(panel: panelImage.size, anchor: settings, visible: canvas)
        let image = NSImage(size: canvas.size)
        image.lockFocus()
        NSColor(calibratedRed: 0.17, green: 0.16, blue: 0.15, alpha: 1).setFill()
        canvas.fill()
        NSColor(white: 0.22, alpha: 1).setFill()
        NSBezierPath(roundedRect: settings, xRadius: 12, yRadius: 12).fill()
        ("System Settings" as NSString).draw(at: NSPoint(x: settings.minX + 20, y: settings.maxY - 36), withAttributes: [
            .font: NSFont.systemFont(ofSize: TypeScale.body, weight: TypeScale.emphasis), .foregroundColor: NSColor(white: 0.8, alpha: 1),
        ])
        panelImage.draw(in: NSRect(origin: origin, size: panelImage.size))
        image.unlockFocus()
        panel.close()
        return image
    }

    static func snapshot(_ view: NSView, backdrop: NSColor?) throws -> NSImage {
        view.displayIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        if let backdrop {
            backdrop.setFill()
            NSRect(origin: .zero, size: view.bounds.size).fill()
        }
        rep.draw(in: NSRect(origin: .zero, size: view.bounds.size))
        image.unlockFocus()
        return image
    }
}

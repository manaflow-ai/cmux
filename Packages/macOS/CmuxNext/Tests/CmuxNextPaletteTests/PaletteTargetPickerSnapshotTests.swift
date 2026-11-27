import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxTheme
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Foundation
import Testing

/// Shared target picker gallery: desktop-ready, paused, unavailable image,
/// and empty inventory, in light and dark. Uses the production palette rows.
@MainActor
@Suite(.paletteRanker, .closesItsWindows)
struct PaletteTargetPickerSnapshotTests {
    private final class Targets: PaletteTargetSource {
        let options: [PaletteTargetOption]
        init(_ options: [PaletteTargetOption]) { self.options = options }
        func targets(of kind: ActionTargetKind) -> [PaletteTargetOption] { options }
    }

    private static func page(options: [PaletteTargetOption]) throws -> PalettePageSpec {
        var descriptor = try #require(ActionCatalog.all.first { $0.id == "cloudOpenDesktop" })
        descriptor.paletteTarget = .machine
        let flow = PaletteArgumentFlow(registry: .standard(), descriptor: descriptor, targets: Targets(options))
        guard case .push(let page) = flow.effect(collected: ActionInvocation()) else { throw CancellationError() }
        return page
    }

    private static func themeInput(dark: Bool) -> ThemeInput {
        dark ? ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xD4D4D4))
            : ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x24292F))
    }

    private static func refresh(_ view: NSView) {
        view.viewDidChangeEffectiveAppearance()
        view.needsLayout = true
        view.needsDisplay = true
        view.subviews.forEach(refresh)
    }

    private static func render(options: [PaletteTargetOption], dark: Bool, windows: inout [NSWindow],
                               scopes: inout [ThemeScope]) async throws -> NSImage {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let palette = PaletteController(registry: ActionRegistry.standard(), sources: PaletteSources(), frecencyPersistence: nil)
        defer { palette.closeForTest() }
        palette.show(page: try page(options: options))
        await palette.model.settle()
        let view = PaletteContentView(model: palette.model)
        view.appearance = appearance
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = view
        windows.append(window)
        // The palette's colors come from the cmux theme, not the window's appearance: give the view the
        // theme a light or dark user has (as PaletteScopeChipSnapshotTests does), then redraw every view.
        let input = Self.themeInput(dark: dark)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(dark ? "Dark+" : "GitHub Light"), input: input, animated: false)
        scope.root(view)
        scopes.append(scope)
        Self.refresh(view)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        // The glass panel itself does not draw through cacheDisplay; its content (field, chips, rows) does,
        // so the content is drawn over an opaque stand-in for the glass.
        let content = view.glass.contentView
        content.layoutSubtreeIfNeeded()
        let bounds = content.bounds.width > 0 ? content.bounds : view.bounds
        let rep = try #require(content.bitmapImageRepForCachingDisplay(in: bounds))
        content.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        // The palette's opaque surface (Reduce Transparency) for this theme stands in for the glass.
        ThemeTokens.derive(from: input).opaqueOverlayFill(lift: ChromeTunables.opaqueOverlayLift.value).nsColor.setFill()
        NSRect(origin: .zero, size: bounds.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: bounds.size), from: .zero, operation: .sourceOver, fraction: 1,
                 respectFlipped: true, hints: nil)
        image.unlockFocus()
        return image
    }

    @Test func drawsLightAndDark() async throws {
        _ = NSApplication.shared
        var windows: [NSWindow] = []
        var scopes: [ThemeScope] = []
        defer { windows.forEach { $0.close() } }
        let setup = PaletteTargetRecovery(action: "cloudSetupDesktop", title: "Set up desktop",
                                          target: ActionTargetRef(kind: .machine, id: "old"))
        let ready = PaletteTargetOption(id: "ready", title: "Design desktop", symbol: "desktopcomputer")
        let paused = PaletteTargetOption(id: "paused", title: "Review desktop", subtitle: "Paused", symbol: "desktopcomputer", accessory: "Resume and open")
        let missing = PaletteTargetOption(id: "old", title: "Cloud Machine 2", subtitle: "Desktop service unavailable", symbol: "desktopcomputer", recovery: setup)
        let states: [(String, [PaletteTargetOption])] = [
            ("Desktop ready first", [ready, paused, missing]),
            ("Resume and open", [paused]),
            ("Older image recovery", [missing]),
            ("First desktop", [PaletteTargetOption(id: "create", title: "Create desktop machine", symbol: "plus",
                                                     recovery: PaletteTargetRecovery(action: "newCloudMachine", title: "Create desktop machine"))]),
        ]
        var cells: [[NSImage]] = []
        for (_, options) in states {
            cells.append([try await Self.render(options: options, dark: false, windows: &windows, scopes: &scopes),
                          try await Self.render(options: options, dark: true, windows: &windows, scopes: &scopes)])
        }
        let cell = cells[0][0].size
        let label: CGFloat = 28
        let sheet = NSImage(size: NSSize(width: cell.width * 2, height: (cell.height + label) * CGFloat(cells.count)))
        sheet.lockFocus()
        NSColor(white: 0.5, alpha: 1).setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: NSColor.white]
        for (row, state) in states.enumerated() {
            let y = sheet.size.height - CGFloat(row + 1) * (cell.height + label)
            for (column, mode) in ["Light", "Dark"].enumerated() {
                cells[row][column].draw(at: NSPoint(x: CGFloat(column) * cell.width, y: y), from: .zero, operation: .sourceOver, fraction: 1)
                ("\(mode): \(state.0)" as NSString).draw(at: NSPoint(x: CGFloat(column) * cell.width + 12, y: y + cell.height + 5),
                                                         withAttributes: attributes)
            }
        }
        sheet.unlockFocus()
        let tiff = try #require(sheet.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        #expect(png.count > 1000)
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fallback = package.appendingPathComponent(".build/palette-targets.png").path
        let path = ProcessInfo.processInfo.environment["CMUX_PALETTE_TARGETS_SNAPSHOT_PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        try png.write(to: URL(fileURLWithPath: path))
    }
}

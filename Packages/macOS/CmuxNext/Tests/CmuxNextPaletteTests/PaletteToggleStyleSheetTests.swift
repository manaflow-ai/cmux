import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxTheme
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// Draws "Toggle Left Sidebar" on and off in every ``PaletteToggleStyle``, light and dark, into one
/// PNG (`.build/toggle-sheet/toggle-styles.png` in the package), for the before/after comparison. It checks only that each style draws; the state itself is checked by
/// `PaletteToggleStateTests`.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct PaletteToggleStyleSheetTests {
    private static let rowSize = NSSize(width: 520, height: 32)

    private static func item(on isOn: Bool) throws -> PaletteItem {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        registry.bind("toggleSidebar") {}
        ActionTargetTitles.setPaletteState("toggleSidebar", in: registry) { isOn }
        return try #require(RegistryPaletteProvider(registry: registry).makeItems().first { $0.actionID == "toggleSidebar" })
    }

    /// Light on the left, dark on the right, in one PNG (`toggle-styles.png`): a fleet step returns one file.
    @Test func drawsEveryStyle() throws {
        let light = try Self.sheet(.aqua)
        let dark = try Self.sheet(.darkAqua)
        let width = light.pixelsWide + dark.pixelsWide
        let height = max(light.pixelsHigh, dark.pixelsHigh)
        let combined = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                     bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: combined)
        light.draw(in: NSRect(x: 0, y: 0, width: light.pixelsWide, height: light.pixelsHigh))
        dark.draw(in: NSRect(x: light.pixelsWide, y: 0, width: dark.pixelsWide, height: dark.pixelsHigh))
        NSGraphicsContext.restoreGraphicsState()
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../.build/toggle-sheet").standardized
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try #require(combined.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("toggle-styles.png"))
        #expect(png.count > 1000)
    }

    /// Every style's row, on (left column) and off (right column), one style per line.
    private static func sheet(_ appearance: NSAppearance.Name) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let dark = appearance == .darkAqua
        let styles = PaletteToggleStyle.allCases
        let sheetSize = NSSize(width: rowSize.width * 2, height: rowSize.height * CGFloat(styles.count))
        let host = NSView(frame: NSRect(origin: .zero, size: sheetSize))
        host.wantsLayer = true
        let input = dark
            ? ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xD4D4D4))
            : ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x24292F))
        host.layer?.backgroundColor = ThemeTokens.derive(from: input).opaqueOverlayFill(lift: ChromeTunables.opaqueOverlayLift.value).nsColor.cgColor
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        defer { window.close() }
        window.contentView = host
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(dark ? "Dark+" : "GitHub Light"), input: input, animated: false)
        scope.root(host)
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(PaletteTunables.all)
        defer { _ = TunableStore.shared.set(PaletteTunables.toggleStyle.key, nil) }
        for (index, style) in styles.enumerated() {
            try #require(TunableStore.shared.set(PaletteTunables.toggleStyle.key, style.tunableValue) == style.tunableValue,
                         "the style takes the override")
            try #require(PaletteTunables.toggleStyle.value == style)
            for (column, isOn) in [true, false].enumerated() {
                let cell = PaletteRowCell(frame: NSRect(x: rowSize.width * CGFloat(column),
                                                        y: sheetSize.height - rowSize.height * CGFloat(index + 1),
                                                        width: rowSize.width, height: rowSize.height))
                host.addSubview(cell)
                cell.configure(PaletteRow(item: try Self.item(on: isOn), highlights: [], score: 0), isSelected: false)
                cell.layoutSubtreeIfNeeded()
            }
        }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }
}

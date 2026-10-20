import AppKit
import CmuxNextDesign
@testable import CmuxNextPalette
import Testing

/// Draws the scope chips ("Scopes" behind "Keyboard Shortcuts") with the old colors and the new ones,
/// light and dark, into a PNG (`CMUX_CHIP_SNAPSHOT_PATH`, else `.build/chip-snapshot.png` in the package).
/// It checks only that the picture is drawn; the colors are checked by `PaletteScopeChipContrastTests`.
@MainActor
@Suite
struct PaletteScopeChipSnapshotTests {
    static let before = (top: PaletteScopeChipInk(text: .primary, icon: .secondary, fill: .selection, outlined: false),
                         back: PaletteScopeChipInk(text: .tertiary, icon: .tertiary, fill: .halfSelection, outlined: false))

    private static func row(top: PaletteScopeChipInk, back: PaletteScopeChipInk, appearance: NSAppearance.Name) -> NSView {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 40))
        row.appearance = NSAppearance(named: appearance)
        row.wantsLayer = true
        row.layer?.backgroundColor = appearance == .darkAqua ? NSColor(white: 0.16, alpha: 1).cgColor : NSColor.white.cgColor
        let chips = [
            PaletteScopeChipView(chip: PaletteScopeChip(levelIndex: 1, scope: .scopes, title: "Scopes", symbol: "square.grid.2x2"),
                                 style: .token, isTop: false, ink: back),
            PaletteScopeChipView(chip: PaletteScopeChip(levelIndex: 2, scope: .shortcuts, title: "Keyboard Shortcuts", symbol: "keyboard"),
                                 style: .token, isTop: true, ink: top),
        ]
        var x: CGFloat = 12
        for chip in chips {
            row.addSubview(chip)
            chip.frame = NSRect(x: x, y: (40 - chip.preferredHeight) / 2, width: chip.fittingWidth, height: chip.preferredHeight)
            chip.layoutSubtreeIfNeeded()
            x += chip.fittingWidth + 8
        }
        return row
    }

    @Test func drawsBeforeAndAfter() throws {
        _ = NSApplication.shared
        let after = (top: PaletteScopeChipInk.ink(isTop: true, increaseContrast: false),
                     back: PaletteScopeChipInk.ink(isTop: false, increaseContrast: false))
        let increased = (top: PaletteScopeChipInk.ink(isTop: true, increaseContrast: true),
                         back: PaletteScopeChipInk.ink(isTop: false, increaseContrast: true))
        let sheet = NSImage(size: NSSize(width: 720, height: 120))
        var windows: [NSWindow] = []
        defer { windows.forEach { $0.close() } }
        let cells: [((top: PaletteScopeChipInk, back: PaletteScopeChipInk), NSAppearance.Name, CGFloat, CGFloat)] = [
            (Self.before, .aqua, 0, 80), (after, .aqua, 360, 80),
            (Self.before, .darkAqua, 0, 40), (after, .darkAqua, 360, 40),
            (increased, .aqua, 0, 0), (increased, .darkAqua, 360, 0),
        ]
        // Each row lives in its own offscreen window with its appearance, so labels, icons and layers
        // resolve their theme colors the way they do in the app.
        var images: [(NSImage, NSPoint)] = []
        for (ink, appearance, x, y) in cells {
            let row = Self.row(top: ink.top, back: ink.back, appearance: appearance)
            let window = NSWindow(contentRect: row.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = row
            windows.append(window)
            row.layoutSubtreeIfNeeded()
            for chip in row.subviews {
                chip.viewDidChangeEffectiveAppearance()
                chip.subviews.forEach { $0.viewDidChangeEffectiveAppearance() }
                chip.needsLayout = true
            }
            row.layoutSubtreeIfNeeded()
            row.displayIfNeeded()
            let rep = try #require(row.bitmapImageRepForCachingDisplay(in: row.bounds))
            row.cacheDisplay(in: row.bounds, to: rep)
            let image = NSImage(size: row.bounds.size)
            image.addRepresentation(rep)
            images.append((image, NSPoint(x: x, y: y)))
        }
        sheet.lockFocus()
        for (image, origin) in images { image.draw(at: origin, from: .zero, operation: .copy, fraction: 1) }
        sheet.unlockFocus()
        let tiff = try #require(sheet.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        #expect(png.count > 1000)
        // Always written into the package's .build (ignored by git), so a fleet step returns it with
        // `cmux-ci run --artifact Packages/macOS/CmuxNext/.build/chip-snapshot.png`.
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fallback = package.appendingPathComponent(".build/chip-snapshot.png").path
        let path: String? = ProcessInfo.processInfo.environment["CMUX_CHIP_SNAPSHOT_PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        if let path { try png.write(to: URL(fileURLWithPath: path)) }
    }
}

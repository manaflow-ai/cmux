import AppKit
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Foundation
import Testing

/// Pictures of the footer's ↩ and ⇥ keycaps for review (#48512 follow-up: the legends sat 1 pt high at 16 and
/// 20 pt). Draws the real footer as PaletteFooterAlignmentTests does, at 2x on the theme's surface, crops the
/// keycaps, scales them up 4x with no smoothing and marks the footer's middle with a red hairline. Writes PNGs to
/// the package's .build/palette-footer-shots (git-ignored), which a fleet step returns with
/// `--artifact Packages/macOS/CmuxNext/.build/palette-footer-shots`. It asserts nothing beyond drawing.
@MainActor
@Suite(.paletteRanker, .closesItsWindows)
struct PaletteFooterKeycapShots {
    @Test func writeFooterKeycapShots() async throws {
        _ = NSApplication.shared
        let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/palette-footer-shots")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let commands = PaletteController(registry: ActionRegistry.standard(), sources: PaletteSources(), frecencyPersistence: nil)
        commands.show(.commands)
        await commands.model.settle()
        defer { commands.closeForTest() }
        var windows: [NSWindow] = []
        defer { windows.forEach { $0.closeAfterTest() } }
        let cases: [(DensityPreset, CGFloat?)] = [(.cozy, nil), (.cozy, 16), (.ultraCompact, 20), (.spacious, nil)]
        for (preset, size) in cases {
            var tokens = preset.tokens
            if let size { tokens.fontSize = size }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let name = "\(preset.tokens.name)-\(size.map { "\(Int($0))pt" } ?? "default")-\(appearance == .aqua ? "light" : "dark")"
                    .lowercased().replacingOccurrences(of: " ", with: "-")
                let png = try DensityTokens.$scoped.withValue(tokens) {
                    try Self.shot(commands.model, appearance: appearance, windows: &windows)
                }
                try png.write(to: out.appendingPathComponent(name + ".png"))
            }
        }
    }

    private static func shot(_ model: PaletteModel, appearance: NSAppearance.Name, windows: inout [NSWindow]) throws -> Data {
        let view = PaletteContentView(model: model)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: PaletteLayout.windowSize), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        windows.append(window)
        view.layoutSubtreeIfNeeded()
        let footer = try #require(Self.descendants(of: view).compactMap { $0 as? PaletteFooterView }.first)
        footer.layoutSubtreeIfNeeded()
        let keys = Self.descendants(of: footer).compactMap { $0 as? PaletteKeycapsView }.filter { !$0.isHiddenOrHasHiddenAncestor }
        let union = keys.map { footer.convert($0.bounds, from: $0) }.reduce(NSRect.null) { $0.union($1) }
        let minX = max(0, union.minX - 8), maxX = min(footer.bounds.width, union.maxX + 8)
        let crop = NSRect(x: minX, y: 0, width: maxX - minX, height: footer.bounds.height)
        let scale: CGFloat = 2, zoom: CGFloat = 4
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(footer.bounds.width * scale),
                                                pixelsHigh: Int(footer.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = footer.bounds.size
        footer.cacheDisplay(in: footer.bounds, to: rep)
        let w = Int(crop.width * scale * zoom), h = Int(crop.height * scale * zoom)
        let image = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                  bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let context = try #require(NSGraphicsContext(bitmapImageRep: image))
        NSGraphicsContext.current = context
        context.imageInterpolation = .none
        (appearance == .aqua ? NSColor(white: 0.97, alpha: 1) : NSColor(white: 0.13, alpha: 1)).setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        // `from` is in the rep's own coordinates: points (rep.size is the footer's), not its pixels.
        rep.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: crop, operation: .sourceOver, fraction: 1,
                 respectFlipped: false, hints: [.interpolation: NSImageInterpolation.none.rawValue])
        NSColor.systemRed.withAlphaComponent(0.8).setFill()
        NSRect(x: 0, y: (footer.bounds.midY - crop.minY) * scale * zoom - 1, width: CGFloat(w), height: 2).fill()
        return try #require(image.representation(using: .png, properties: [:]))
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }
}

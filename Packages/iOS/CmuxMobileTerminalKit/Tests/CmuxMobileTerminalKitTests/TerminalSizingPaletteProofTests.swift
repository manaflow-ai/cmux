#if canImport(AppKit)
import AppKit
import Foundation
import Testing
@testable import CmuxMobileTerminalKit

/// Opt-in visual proof: set `CMUX_THEME_PROOF_DIR` to render, per theme, the
/// iOS surface chrome (border, hatch, chip, cut fade) and a size-sheet avatar
/// row drawn with ``TerminalSizingPalette``. Geometry mirrors
/// `GhosttySurfaceSharedSizingLayers` (capsule chip, caption2 monospaced
/// digits, 1 pt border, 8 pt hatch); UIKit itself does not run here.
@Suite struct TerminalSizingPaletteProofTests {
    static let themes: [(name: String, background: String, foreground: String)] = [
        ("light", "#ffffff", "#1d1d1f"),
        ("dark", "#272822", "#fdfff1"),
        ("solarized-light", "#fdf6e3", "#657b83"),
        ("solarized-dark", "#002b36", "#839496"),
        ("dracula", "#282a36", "#f8f8f2"),
        ("low-contrast-dark", "#1e1e1e", "#3a3a3a"),
        ("mid-grey", "#808080", "#ffffff"),
    ]

    @Test func renderThemeProofs() throws {
        guard let directory = ProcessInfo.processInfo.environment["CMUX_THEME_PROOF_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for theme in Self.themes {
            let palette = TerminalSizingPalette(
                background: try #require(.init(hex: theme.background)),
                foreground: try #require(.init(hex: theme.foreground))
            )
            let data = try #require(Self.render(palette))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("ios-\(theme.name).png"))
        }
        // The size sheet on system light and dark inset-grouped rows.
        for (name, background, foreground) in [("light", "#ffffff", "#000000"), ("dark", "#1c1c1e", "#ffffff")] {
            let palette = TerminalSizingPalette(
                background: try #require(.init(hex: background)),
                foreground: try #require(.init(hex: foreground))
            )
            let data = try #require(Self.renderSheetRow(palette))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("ios-sheet-\(name).png"))
        }
    }

    private static func color(_ rgb: TerminalSizingPalette.RGB, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: alpha)
    }

    private static func png(size: NSSize, draw: () -> Void) -> Data? {
        let scale: CGFloat = 3
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        guard let bitmap = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        // Top-left origin, like UIKit.
        bitmap.cgContext.translateBy(x: 0, y: size.height)
        bitmap.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap.cgContext, flipped: true)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private static func render(_ palette: TerminalSizingPalette) -> Data? {
        let size = NSSize(width: 390, height: 260)
        return png(size: size) {
            color(palette.background).setFill()
            NSRect(origin: .zero, size: size).fill()
            let grid = NSRect(x: 0, y: 0, width: 390, height: 170)
            // Text, with a cut fade on the bottom edge.
            let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            for (index, line) in ["$ claude", "> Refactor the sizing palette", "  Reading 4 files…", "  Editing Sizing.swift", "  Running tests…", "  All 12 themes pass", "$ git status", "  3 files changed", "$ "].enumerated() {
                (line as NSString).draw(
                    at: NSPoint(x: 8, y: 6 + CGFloat(index) * 18),
                    withAttributes: [.font: mono, .foregroundColor: color(palette.foreground)]
                )
            }
            let fadeRect = NSRect(x: grid.minX, y: grid.maxY - 16, width: grid.width, height: 16)
            NSGradient(starting: color(palette.background, alpha: 0), ending: color(palette.background, alpha: 0.85))?
                .draw(in: fadeRect, angle: 90)
            // Hatch below the grid.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: 0, y: grid.maxY, width: size.width, height: size.height - grid.maxY)).addClip()
            let hatch = NSBezierPath()
            var x = -size.height
            while x < size.width {
                hatch.move(to: NSPoint(x: x, y: size.height))
                hatch.line(to: NSPoint(x: x + size.height, y: 0))
                x += 8
            }
            hatch.lineWidth = 1
            color(palette.hatch).setStroke()
            hatch.stroke()
            NSGraphicsContext.restoreGraphicsState()
            // Border on the side facing unused space.
            let border = NSBezierPath()
            border.move(to: NSPoint(x: 0, y: grid.maxY - 0.5))
            border.line(to: NSPoint(x: size.width, y: grid.maxY - 0.5))
            border.lineWidth = 1
            color(palette.line).setStroke()
            border.stroke()
            // Chip under the grid.
            let chipFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            let title = "118×38 · Maya's Mac Studio" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: chipFont, .foregroundColor: color(palette.glyph)]
            let textSize = title.size(withAttributes: attributes)
            let chip = NSRect(x: (size.width - textSize.width - 20) / 2, y: grid.maxY + 12, width: textSize.width + 20, height: textSize.height + 10)
            let capsule = NSBezierPath(roundedRect: chip.insetBy(dx: 0.5, dy: 0.5), xRadius: chip.height / 2, yRadius: chip.height / 2)
            color(palette.fill).setFill()
            capsule.fill()
            color(palette.line).setStroke()
            capsule.lineWidth = 1
            capsule.stroke()
            title.draw(at: NSPoint(x: chip.minX + 10, y: chip.minY + 5), withAttributes: attributes)
        }
    }

    private static func renderSheetRow(_ palette: TerminalSizingPalette) -> Data? {
        let size = NSSize(width: 320, height: 56)
        return png(size: size) {
            color(palette.background).setFill()
            NSRect(origin: .zero, size: size).fill()
            let avatar = NSRect(x: 16, y: 14, width: 28, height: 28)
            color(palette.fill).setFill()
            NSBezierPath(ovalIn: avatar).fill()
            let ring = NSBezierPath(ovalIn: avatar.insetBy(dx: -2, dy: -2))
            ring.lineWidth = 1
            color(palette.line).setStroke()
            ring.stroke()
            let initial = "M" as NSString
            let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            let glyphAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color(palette.glyph)]
            let initialSize = initial.size(withAttributes: glyphAttributes)
            initial.draw(at: NSPoint(x: avatar.midX - initialSize.width / 2, y: avatar.midY - initialSize.height / 2), withAttributes: glyphAttributes)
            ("Maya Ortiz · Mac Studio" as NSString).draw(
                at: NSPoint(x: 56, y: 19),
                withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: color(palette.foreground)]
            )
        }
    }
}
#endif

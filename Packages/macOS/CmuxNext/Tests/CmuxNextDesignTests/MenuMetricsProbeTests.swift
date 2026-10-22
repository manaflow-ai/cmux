import AppKit
import CmuxTheme
@testable import CmuxNextDesign
import Testing

/// Capture probe (not for merge): renders the chat's selection menu rows, themed, into
/// menu-probe.png at the repo root, at 2x, over a dark glass-like panel.
@MainActor @Suite struct MenuMetricsProbeTests {
    @Test func renderSelectionMenu() throws {
        var input = ThemeInput(background: ThemeRGB(hex: 0x1C1B22), foreground: ThemeRGB(hex: 0xE8E4F0))
        input.accentColor = ThemeRGB(hex: 0x5B8DEF)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec("Probe Blue"), input: input, animated: false)

        let menu = NSMenu()
        for (title, symbol) in [("Copy", "doc.on.doc"), ("Quote in Reply", "text.quote"), ("Ask About This", "questionmark.bubble"),
                                ("-", ""), ("Search the Web", "magnifyingglass")] {
            if title == "-" { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: title, action: #selector(NSText.copy(_:)), keyEquivalent: "")
            item.image = .menuSymbol(symbol)
            menu.addItem(item)
        }
        menu.themeRows(in: scope)

        let pad: CGFloat = 5, separatorHeight: CGFloat = 10, scale: CGFloat = 2
        let width = menu.items.compactMap { $0.view?.frame.width }.max() ?? 200
        let height = pad * 2 + menu.items.reduce(0) { $0 + ($1.isSeparatorItem ? separatorHeight : ($1.view?.frame.height ?? 22)) }
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale), bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = NSSize(width: width, height: height)
        // Each row draws itself into its own bitmap, then lands at its place, top to bottom.
        var rows: [(NSRect, NSBitmapImageRep?)] = []
        var top = pad
        for (index, item) in menu.items.enumerated() {
            if item.isSeparatorItem {
                rows.append((NSRect(x: 0, y: height - top - separatorHeight, width: width, height: separatorHeight), nil))
                top += separatorHeight
                continue
            }
            let row = try #require(item.view as? ThemedMenuRowView)
            row.appearance = NSAppearance(named: .darkAqua)
            row.highlightOverride = index == 1
            row.setFrameSize(NSSize(width: width, height: row.frame.height))
            let image = try #require(row.bitmapImageRepForCachingDisplay(in: row.bounds))
            row.cacheDisplay(in: row.bounds, to: image)
            rows.append((NSRect(x: 0, y: height - top - row.frame.height, width: width, height: row.frame.height), image))
            top += row.frame.height
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.16, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        for (rect, image) in rows {
            if let image {
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            } else {
                NSColor(white: 1, alpha: 0.14).setFill()
                NSRect(x: 15, y: rect.midY - 0.5, width: width - 30, height: 1).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let png = try #require(rep.representation(using: .png, properties: [:]))
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        try png.write(to: root.appendingPathComponent("menu-probe.png"))
        print("menu-probe: \(width)x\(height)pt rows=\(menu.items.map { $0.view?.frame.height ?? -1 })")
    }
}

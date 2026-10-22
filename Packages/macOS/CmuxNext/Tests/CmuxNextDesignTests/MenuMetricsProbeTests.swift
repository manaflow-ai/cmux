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

        let pad: CGFloat = 5, separatorHeight: CGFloat = 10
        let width = menu.items.compactMap { $0.view?.frame.width }.max() ?? 200
        let height = pad * 2 + menu.items.reduce(0) { $0 + ($1.isSeparatorItem ? separatorHeight : ($1.view?.frame.height ?? 22)) }
        let panel = ProbePanel(frame: NSRect(x: 0, y: 0, width: width, height: height))
        panel.appearance = NSAppearance(named: .darkAqua)
        var y = pad
        for (index, item) in menu.items.enumerated() {
            if item.isSeparatorItem {
                let line = ProbeSeparator(frame: NSRect(x: 0, y: y, width: width, height: separatorHeight))
                panel.addSubview(line)
                y += separatorHeight
                continue
            }
            let row = try #require(item.view as? ThemedMenuRowView)
            row.highlightOverride = index == 1
            row.frame = NSRect(x: 0, y: y, width: width, height: row.frame.height)
            panel.addSubview(row)
            y += row.frame.height
        }

        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2), bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = panel.bounds.size
        panel.cacheDisplay(in: panel.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        try png.write(to: root.appendingPathComponent("menu-probe.png"))
        print("menu-probe: \(width)x\(height)pt rows=\(menu.items.map { $0.view?.frame.height ?? -1 })")
    }
}

private final class ProbePanel: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.16, alpha: 1).setFill()
        bounds.fill()
    }
}

private final class ProbeSeparator: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1, alpha: 0.14).setFill()
        NSRect(x: 15, y: bounds.midY - 0.5, width: bounds.width - 30, height: 1).fill()
    }
}

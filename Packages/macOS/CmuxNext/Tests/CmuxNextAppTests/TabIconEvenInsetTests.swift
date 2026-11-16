import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextIcons
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-11-12, on a terminal tab: "i feel like space on left/top of tab is not even". The
/// tab's icon is measured as drawn: the terminal glyph's ink sits as far from its pill's leading
/// edge as from the pill's top and bottom (within a 2x device pixel), in the default strip and
/// under Compact tabs. Before the fix the ink sat 10 pt in from the leading edge and 8 pt from the
/// top at Compact density (the icon box 8 pt in, centered vertically).
@MainActor @Suite(.serialized, .closesItsWindows) struct TabIconEvenInsetTests {
    @Test(arguments: [false, true]) func theTerminalGlyphSitsAsFarFromTheLeadingEdgeAsFromTheTop(compactTabs: Bool) throws {
        let key = ChromeTunables.compactTabs.descriptor.key
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register([ChromeTunables.compactTabs.descriptor])
        if compactTabs { try #require(TunableStore.shared.set(key, .bool(true)) == .bool(true), "the toggle takes the override") }
        defer { TunableStore.shared.set(key, nil) }

        let model = TabStripModel(tabs: (0..<3).map { TabItem(id: TabID("tab\($0)"), title: "~/fun/cmuxterm-hq", icon: .icon(.tabTerminal)) },
                                  selectedID: TabID("tab0"))
        let strip = TabStripView(model: model)
        strip.dragsWindowFromEmptySpace = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: TabStripView.preferredHeight), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        window.contentView = strip
        window.orderFrontRegardless()
        strip.layoutSubtreeIfNeeded()

        for id in ["tab0", "tab1"] {
            let cell = try #require(strip.cells[TabID(id)])
            let pill = cell.backgroundLayer.frame
            let icon = cell.iconLayer.frame
            let contents = try #require(cell.iconLayer.contents as CFTypeRef?, "\(id) draws no icon")
            try #require(CFGetTypeID(contents) == CGImage.typeID, "\(id)'s icon is not an image")
            let image = unsafeDowncast(contents, to: CGImage.self)
            let ink = try #require(Self.inkBounds(image), "\(id)'s icon has no ink")
            // Image pixels per point; the layer draws the image aspect-fit in its box (a square image in a square box).
            let perPoint = CGFloat(image.width) / icon.width
            let leading = icon.minX - pill.minX + ink.minX / perPoint
            // Image rows run top down; the two vertical gaps are both checked, so the layer's flip does not matter.
            let above = icon.minY - pill.minY + ink.minY / perPoint
            let below = pill.maxY - (icon.minY + ink.maxY / perPoint)
            let tolerance: CGFloat = 0.5
            #expect(abs(leading - above) <= tolerance && abs(leading - below) <= tolerance,
                    "\(id) (compact tabs \(compactTabs)): the glyph's ink is \(leading) pt from the pill's leading edge, \(above) and \(below) pt from its top and bottom (pill \(pill), icon \(icon))")
        }
    }

    /// The bounding box, in image pixels with rows top down, of the pixels at least a third opaque.
    static func inkBounds(_ image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] >= 85 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX + 1 - minX, height: maxY + 1 - minY)
    }
}

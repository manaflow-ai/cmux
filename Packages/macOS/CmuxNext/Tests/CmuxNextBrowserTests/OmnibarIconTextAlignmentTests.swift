import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Lucas 2026-11-16: "make sure that the search icon and the input text are aligned on the omnibar please, vertically
/// aligned". The chip's icon and the URL's text share one center line at every density, whatever their sizes.
@MainActor @Suite(.serialized) struct OmnibarIconTextAlignmentTests {
    private func capitalCenter(_ field: NSTextField) throws -> CGFloat {
        let size = field.bounds.size
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        field.cacheDisplay(in: field.bounds, to: rep)
        var minY = Int.max, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) >= 0.25 {
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        try #require(maxY >= minY, "the address drew no text")
        return field.convert(NSPoint(x: 0, y: CGFloat(minY + maxY + 1) / 4), to: nil).y
    }

    @Test(arguments: DensityPreset.allCases)
    func theIconAndTheTextShareOneCenterLine(preset: DensityPreset) throws {
        try DensityTokens.$scoped.withValue(preset.tokens) {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.orderOut(nil) }
            let page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
            let chrome = BrowserChromeView(tab: page)
            chrome.frame = window.contentLayoutRect
            window.contentView = chrome
            chrome.layoutSubtreeIfNeeded()
            let bar = chrome.addressBar
            bar.field.stringValue = "HHHHHHHH"
            bar.layoutSubtreeIfNeeded()
            let icon = bar.chip.subviews.compactMap { $0 as? NSImageView }.first { !$0.isHidden }
            let image = try #require(icon, "\(preset): no chip icon")
            let iconFrame = image.convert(image.bounds, to: nil)
            // The cell draws through TextKit, whose baseline differs from NSTextField's reported one.
            let capCenter = try capitalCenter(bar.field)
            #expect(abs(iconFrame.midY - capCenter) <= 0.5,
                    "\(preset): the icon's center is \(iconFrame.midY), the text's capitals center on \(capCenter)")
        }
    }

    /// The bar measures the text's shift after it sets the density's font, not before: the field's own binding runs in
    /// another loop, so a shift bound beside the other constraints could keep the replaced font's offset (review
    /// 2026-11-16).
    @Test(arguments: DensityPreset.allCases)
    func theShiftFollowsTheFontTheDensitySets(preset: DensityPreset) throws {
        try DensityTokens.$scoped.withValue(preset.tokens) {
            let page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
            let bar = BrowserChromeView(tab: page).addressBar
            let center = try #require(bar.constraints.first { ($0.firstItem as? NSView) === bar.field && $0.firstAttribute == .centerY },
                                      "\(preset): no center constraint on the field")
            // The font a density switch replaces, still on the field when the bar's binding runs.
            bar.field.font = NSFont.systemFont(ofSize: 30)
            bar.density.reapply()
            #expect(abs((bar.field.font?.pointSize ?? 0) - OmnibarStyle.font.pointSize) < 0.01)
            #expect(abs(center.constant - OmnibarStyle.fieldBaselineShift(field: bar.field)) < 0.01,
                    "\(preset): the shift is \(center.constant), the density's font needs \(OmnibarStyle.fieldBaselineShift(field: bar.field))")
        }
    }
}

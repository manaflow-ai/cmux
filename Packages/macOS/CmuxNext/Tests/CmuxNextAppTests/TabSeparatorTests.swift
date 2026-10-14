import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// Some separator between tabs, minimal but noticeable (Leo 2026-10-14): a short 1 pt line in
/// the gap between two tabs, in the theme's separator tone, and none beside the selected or the
/// hovered tab (Safari, Chrome), so it never cuts into the selected tab's shape. Read from the
/// strip as drawn, in the default and the compact strip. Behind the Debug Settings toggle
/// `tabs.separators`, off by default.
@MainActor @Suite(.serialized) struct TabSeparatorTests {
    /// What the eye gets in the gap after each tab: the largest luminance step (0-255) from the
    /// strip's background along the gap's middle row.
    static func gapContrast(_ strip: TabStripView, tabs: Int) throws -> [Int] {
        let scale: CGFloat = 2
        let size = strip.bounds.size
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 4 * width,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(Palette.chromeBackground.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        try #require(strip.layer).render(in: context)
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        // The strip's middle row and its edge rows (background around the tabs) are the same rows
        // whichever way the bitmap counts them.
        func luminance(_ x: Int, _ y: Int) -> Int {
            let i = 4 * (y * width + x)
            return (Int(pixels[i]) * 299 + Int(pixels[i + 1]) * 587 + Int(pixels[i + 2]) * 114) / 1000
        }
        return try (0..<tabs).map { index in
            let cell = try #require(strip.cells[TabID("tab\(index)")])
            let frame = strip.convert(cell.frame, from: strip.tabsClip)
            let pill = cell.metrics.pillFrame(slotWidth: frame.width, height: frame.height)
            let xs = Int((frame.minX + pill.maxX) * scale)..<Int(frame.maxX * scale)
            let mid = Int(frame.midY * scale)
            return xs.map { abs(luminance($0, mid) - luminance($0, 1)) }.max() ?? 0
        }
    }

    static func strip(tabs: Int) -> (TabStripView, NSWindow) {
        let model = TabStripModel(tabs: (0..<tabs).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)") }, selectedID: TabID("tab1"))
        let strip = TabStripView(model: model)
        strip.dragsWindowFromEmptySpace = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: TabStripView.preferredHeight), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = strip
        window.orderFrontRegardless()
        strip.layoutSubtreeIfNeeded()
        return (strip, window)
    }

    /// Tab 1 is selected and tab 3 hovered: the gaps after tabs 0, 1, 2 and 3 touch one of them
    /// and stay clear; the gap after tab 4 (to the +) shows the line, as does none other.
    func checkSeparators() throws {
        let (strip, window) = Self.strip(tabs: 5)
        defer { window.orderOut(nil) }
        let hovered = try #require(strip.cells[TabID("tab3")])
        let frame = strip.convert(hovered.frame, from: strip.tabsClip)
        TabStripDebug.pointerMoved(in: strip, to: CGPoint(x: frame.midX, y: frame.midY))
        let contrast = try Self.gapContrast(strip, tabs: 5)

        let noticeable = 20, clear = 4
        #expect(contrast[4] >= noticeable, "the line after the last tab is \(contrast[4])/255 from the strip: \(contrast)")
        #expect(contrast[0...3].allSatisfy { $0 <= clear }, "a line beside the selected or hovered tab: \(contrast)")

        TabStripDebug.pointerMoved(in: strip, to: CGPoint(x: -50, y: -50))
        let rested = try Self.gapContrast(strip, tabs: 5)
        #expect([2, 3, 4].allSatisfy { rested[$0] >= noticeable }, "unselected neighbors are apart: \(rested)")
        #expect(rested[0] <= clear && rested[1] <= clear, "a line touches the selected tab: \(rested)")
    }

    /// Debug Settings overrides for this test only (the store is active without a file, so nothing
    /// is written): the separators toggle, and Compact tabs when asked.
    func withOverrides(separators: Bool, compact: Bool, _ body: () throws -> Void) throws {
        TunableStore.shared.activate(file: nil)
        let separatorsKey = "tabs.separators", compactKey = ChromeTunables.compactTabs.descriptor.key
        TunableStore.shared.register(TabTunables.all + [ChromeTunables.compactTabs.descriptor])
        try #require(TunableStore.shared.set(separatorsKey, .bool(separators)) == .bool(separators), "the separators toggle takes the override")
        try #require(TunableStore.shared.set(compactKey, .bool(compact)) == .bool(compact), "the compact toggle takes the override")
        defer {
            TunableStore.shared.set(separatorsKey, nil)
            TunableStore.shared.set(compactKey, nil)
        }
        try body()
    }

    @Test func aShortLineSitsBetweenTabsAndNeverBesideTheSelectedOrHoveredOne() throws {
        try withOverrides(separators: true, compact: false) { try checkSeparators() }
    }

    @Test func theCompactStripHasTheSameLines() throws {
        try withOverrides(separators: true, compact: true) { try checkSeparators() }
    }

    /// Lawrence removed the lines (7f9fc1ed): they are opt-in until the default call is made.
    @Test func theStripDrawsNoLinesWhileTheToggleIsOff() throws {
        try withOverrides(separators: false, compact: false) {
            let (strip, window) = Self.strip(tabs: 5)
            defer { window.orderOut(nil) }
            let contrast = try Self.gapContrast(strip, tabs: 5)
            #expect(contrast.allSatisfy { $0 <= 4 }, "a line between tabs with the toggle off: \(contrast)")
        }
    }
}

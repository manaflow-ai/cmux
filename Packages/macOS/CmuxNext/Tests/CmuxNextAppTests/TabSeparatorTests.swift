import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Some separator between tabs, minimal but noticeable (Leo 2026-10-14): a short 1 pt line in
/// the gap between two tabs, in the theme's separator tone, and none beside the selected or the
/// hovered tab (Safari, Chrome), so it never cuts into the selected tab's shape. Read from the
/// strip as drawn, in the default and the compact strip. Behind the Debug Settings toggle
/// `tabs.separators`, off by default.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabSeparatorTests {
    /// What the eye gets in the gap after each tab: the luminance step (0-255) a line there makes
    /// over the strip's background, 0 with no visible line. A line is a sublayer of the tab at most
    /// 1 pt wide, on the pixel grid, inside the gap after the pill, shown and colored.
    static func gapContrast(_ strip: TabStripView, tabs: Int) throws -> [Int] {
        let scale = strip.window?.backingScaleFactor ?? 2
        let background = try #require(Palette.chromeBackground.usingColorSpace(.sRGB))
        func luminance(_ color: NSColor) -> CGFloat { 0.299 * color.redComponent + 0.587 * color.greenComponent + 0.114 * color.blueComponent }
        return try (0..<tabs).map { index in
            let cell = try #require(strip.cells[TabID("tab\(index)")])
            let slot = cell.layer.bounds
            let pill = cell.metrics.pillFrame(slotWidth: slot.width, height: slot.height)
            let lines = (cell.layer.sublayers ?? []).filter { line in
                line.frame.width > 0 && line.frame.width <= 1 + 0.001 && line.frame.height > 2 && line.frame.minX >= pill.maxX - 0.001
                    && line.frame.maxX <= slot.maxX + 0.001 && !line.isHidden && line.opacity > 0 && line.backgroundColor != nil
            }
            guard let line = lines.first, let cg = line.backgroundColor, let color = NSColor(cgColor: cg)?.usingColorSpace(.sRGB) else { return 0 }
            #expect((line.frame.minX * scale).rounded() == line.frame.minX * scale, "the line at x \(line.frame.minX) is off the pixel grid")
            #expect(line.frame.height >= slot.height * 0.4 && line.frame.height <= slot.height * 0.7,
                    "the line is \(line.frame.height) pt of a \(slot.height) pt tab")
            let alpha = color.alphaComponent * CGFloat(line.opacity)
            let over = luminance(color) * alpha + luminance(background) * (1 - alpha)
            return Int((abs(over - luminance(background)) * 255).rounded())
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
        defer { window.closeAfterTest() }
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
        // Not required: a build without the toggle draws no lines, and the line checks say so.
        TunableStore.shared.set(separatorsKey, .bool(separators))
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
            defer { window.closeAfterTest() }
            let contrast = try Self.gapContrast(strip, tabs: 5)
            #expect(contrast.allSatisfy { $0 <= 4 }, "a line between tabs with the toggle off: \(contrast)")
        }
    }
}

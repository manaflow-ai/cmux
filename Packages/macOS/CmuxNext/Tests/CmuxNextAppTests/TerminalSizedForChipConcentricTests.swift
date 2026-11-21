import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Foundation
import Testing

/// The "Sized for" chip is concentric with the corner it sits in, and Take over with the chip
/// (user, Nov 9: "the chip looks ugly like we need it to be concentric", "take over button needs to
/// be concentric"). The chip sits ``Metrics/panelInset`` inside the terminal pane's bottom-trailing
/// corner, so its radius is the pane's corner (the main pane's, concentric with the window, or a
/// floating pane's card) less that inset; Take over sits the same gap from the chip's top, bottom
/// and trailing edges, and its radius is the chip's less that gap.
@MainActor @Suite(.serialized, .closesItsWindows) struct TerminalSizedForChipConcentricTests {
    /// The pane corner the chip nests in, by a1050's rule (ce0d819, 960894e).
    private static var paneCorner: CGFloat {
        Metrics.floatingPanes ? Metrics.floatingPaneCornerRadius
            : Metrics.mainPaneCornerRadius(windowCornerRadius: Metrics.standardWindowCornerRadius)
    }

    private static func mountedChip() throws -> (NSWindow, TerminalSizedForChip, NSButton) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 460, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 120))
        window.contentView = root
        let chip = TerminalSizedForChip()
        root.addSubview(chip)
        chip.show(TerminalSizedFor(deviceName: "Maya's iPhone", deviceKind: "iphone", sameDevice: false,
                                   grid: TerminalGridSize(columns: 54, rows: 44)))
        chip.frame = CGRect(origin: CGPoint(x: 20, y: 20), size: chip.fittingSize)
        chip.layoutSubtreeIfNeeded()
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let button = try #require(all(chip).compactMap { $0 as? NSButton }.first)
        return (window, chip, button)
    }

    @Test func theChipIsConcentricWithThePaneCorner() throws {
        let (window, chip, _) = try Self.mountedChip()
        defer { window.close() }
        let expected = min(max(0, Self.paneCorner - Metrics.panelInset), chip.bounds.height / 2)
        #expect(chip.layer?.cornerRadius == expected,
                "chip radius \(chip.layer?.cornerRadius ?? -1), pane corner \(Self.paneCorner) less inset \(Metrics.panelInset)")
    }

    @Test func takeOverIsConcentricWithTheChip() throws {
        let (window, chip, button) = try Self.mountedChip()
        defer { window.close() }
        let frame = button.convert(button.bounds, to: chip)
        let top = chip.bounds.maxY - frame.maxY
        let bottom = frame.minY - chip.bounds.minY
        let trailing = chip.bounds.maxX - frame.maxX
        #expect(top == bottom && bottom == trailing, "Take over's gaps: top \(top), bottom \(bottom), trailing \(trailing)")
        let chipRadius = chip.layer?.cornerRadius ?? 0
        #expect(button.layer?.cornerRadius == max(0, chipRadius - trailing),
                "Take over radius \(button.layer?.cornerRadius ?? -1), chip \(chipRadius) less gap \(trailing)")
    }

    /// The rule in numbers: each radius is the one around it less the gap, never below 0 or past half the chip.
    @Test(arguments: [
        (pane: CGFloat(10), inset: CGFloat(6), height: CGFloat(24), gap: CGFloat(3), chip: CGFloat(4), button: CGFloat(1)),
        (pane: 12, inset: 6, height: 24, gap: 3, chip: 6, button: 3),
        (pane: 4, inset: 6, height: 24, gap: 3, chip: 0, button: 0),
        (pane: 40, inset: 6, height: 24, gap: 3, chip: 12, button: 9),
    ])
    func radiiNestByTheGap(_ c: (pane: CGFloat, inset: CGFloat, height: CGFloat, gap: CGFloat, chip: CGFloat, button: CGFloat)) {
        let radii = TerminalSizedForChip.cornerRadii(paneCornerRadius: c.pane, chipInset: c.inset, chipHeight: c.height, buttonGap: c.gap)
        #expect(radii.chip == c.chip)
        #expect(radii.button == c.button)
    }
}

import AppKit
@testable import CmuxNextDesign
import CmuxNextIcons
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// https://github.com/manaflow-ai/cmux/issues/49583 ("are all of these the same size icons wise… look at the top left
/// one… fix the problem"): a pinned row's leading pin drew larger than a hovered row's Pin, and the hovered row's ⋮ and
/// ✕ drew at two other sizes (the ⋮ at `smallIconSize - space1`, the pin and ✕ at `smallIconSize - space2`, the leading
/// pin fitted to the rows' optical square), so one row showed three sizes and three stroke weights. Every row symbol
/// now draws at `SidebarStyle.rowSymbolSide`, in one `controlSize` hit box on the row's center line, at every density
/// and text size.
@MainActor @Suite(.closesItsWindows, .serialized) struct SidebarRowSymbolsShareOneSizeTests {
    nonisolated static let cases: [HomePinnedRowAlignmentTests.Case] = SidebarTextSize.allCases.flatMap { textSize in
        SidebarDensity.allCases.map { HomePinnedRowAlignmentTests.Case(density: $0, minimal: .off, width: 260, textSize: textSize) }
    }

    /// Device pixels at 2x, and the half-point snap of `rowSymbolSide` against the leading pin's pixel-snapped frame.
    static let tolerance: CGFloat = 0.51

    static func side(_ button: SidebarIconButton) throws -> CGFloat {
        try #require(button.image, "\(button.accessibilityLabel() ?? "a control") drew no glyph").size.width
    }

    @Test(arguments: cases, DensityPreset.allCases)
    func aHoveredRowsControlsAndTheLeadingPinShareOneSize(_ c: HomePinnedRowAlignmentTests.Case, preset: DensityPreset) throws {
        try HomePinnedRowAlignmentTests.at(c, preset: preset) {
            let (list, window) = SidebarLeadingEdgeTests.list(width: c.width)
            defer { window.close() }
            let side = SidebarStyle.rowSymbolSide
            #expect(side > 0 && side <= SidebarStyle.controlSize, "\(c.testDescription): the row symbol side \(side) fits a control")

            // The pinned row's leading pin draws at the one side.
            let pinRow = try HomePinnedRowAlignmentTests.item(list, SidebarLeadingEdgeTests.pins[0].id)
            let leading = try #require(pinRow.pinSquareFrame, "\(c.testDescription): the pinned row drew no pin")
            #expect(abs(leading.width - side) <= Self.tolerance,
                    "\(c.testDescription): the leading pin is \(leading.width) pt, the hover controls \(side) pt")

            // A hovered workspace row's Pin, ⋮ and ✕: one glyph side, one hit box, one center line.
            let row = try HomePinnedRowAlignmentTests.row(list, SidebarLeadingEdgeTests.pinning)
            // The App wires these; a row without a menu or a pin action shows neither on hover.
            row.isPinned = { false }
            row.onMore = {}
            row.onPin = {}
            row.onClose = {}
            row.isHovered = true
            row.needsLayout = true
            row.layoutSubtreeIfNeeded()
            let pin = row.pinButton, more = row.moreButton, close = row.closeButton
            for (name, glyph) in [("Pin", try Self.side(pin)), ("✕", try Self.side(close)),
                                  ("⋮", try #require(more.drawnGlyph, "the ⋮ drew no glyph").size.width)] {
                #expect(abs(glyph - side) < 0.01, "\(c.testDescription): the hover \(name) draws at \(glyph) pt, the row symbols at \(side)")
            }
            let frames: [(String, NSView)] = [("Pin", pin), ("⋮", more), ("✕", close)]
            for (name, view) in frames where !view.isHidden {
                #expect(abs(view.frame.width - SidebarStyle.controlSize) < 0.01 && abs(view.frame.height - SidebarStyle.controlSize) < 0.01,
                        "\(c.testDescription): the hover \(name)'s hit box is \(view.frame.size), a control is \(SidebarStyle.controlSize)")
                #expect(abs(view.frame.midY - close.frame.midY) < 0.01, "\(c.testDescription): the hover \(name) leaves the ✕'s center line")
            }

            // The tree's chevron and the speaker are row controls too.
            #expect(abs(try Self.side(row.treeFoldButton.shownForTest()) - side) < 0.01, "\(c.testDescription): the tree chevron's size")
            #expect(abs(try Self.side(row.audioButton.shownForTest()) - side) < 0.01, "\(c.testDescription): the speaker's size")
        }
    }

    /// The pinned rows' and group headers' hover controls come from the same makers, so they take the same side.
    @Test(arguments: DensityPreset.allCases)
    func everyRowControlMakerTakesTheOneSide(preset: DensityPreset) throws {
        try DensityTokens.$scoped.withValue(preset.tokens) {
            let window = TwoXWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let root = NSView(frame: window.contentLayoutRect)
            window.contentView = root
            let side = SidebarStyle.rowSymbolSide
            for icon in [IconName.browserToolbarUnpin, .actionPin, .actionClose, .disclosureExpanded] {
                let button = SidebarIconButton.rowControl(icon: icon, label: icon.rawValue)
                root.addSubview(button)
                button.layoutSubtreeIfNeeded()
                #expect(abs(try Self.side(button) - side) < 0.01, "\(preset): \(icon.rawValue) draws off the row symbol side")
            }
            let more = OverflowButton.rowControl(label: "More")
            root.addSubview(more)
            more.layoutSubtreeIfNeeded()
            let glyph = try #require(more.drawnGlyph, "the ⋮ drew no glyph").size.width
            #expect(abs(glyph - side) < 0.01, "\(preset): the row ⋮ draws at \(glyph), the row symbols at \(side)")
            // The app's other ⋮ (pane toolbars, cards) keeps its own size.
            #expect(OverflowButton(label: "More").drawnGlyph?.size.width == OverflowButton.glyphSize)
        }
    }
}

private extension SidebarIconButton {
    /// Shows the button so it draws its glyph (a hidden control makes none, REOPEN-F7).
    func shownForTest() -> SidebarIconButton {
        isHidden = false
        layoutSubtreeIfNeeded()
        return self
    }
}

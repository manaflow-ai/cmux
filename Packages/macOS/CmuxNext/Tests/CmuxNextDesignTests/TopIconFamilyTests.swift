import AppKit
import CmuxNextDesign
import CmuxNextIcons
import Testing

/// The top area's icons are one family (Leo 2026-11-07: "we need to make sure that the icons all look
/// good and as if they were from the same family and the same sizing and the same, like, ratios and
/// justifications ... Why is the puzzle icon so ... big?"): every browser toolbar glyph has the back
/// arrow's ink box, centered, and every surface reads the shared tokens.
@MainActor @Suite struct TopIconFamilyTests {
    /// The browser toolbar's glyphs: navigation, the bookmark star, the Extensions puzzle and the
    /// pinnable buttons. Each one's ink must be the back arrow's.
    private static let toolbarGlyphs: [IconName] = [
        .browserToolbarBack, .browserToolbarForward, .browserToolbarReload,
        .browserOmniboxStar, .browserOmniboxStarActive,
        .browserToolbarExtensions, .browserToolbarExtensionsCrashed,
        .browserToolbarDownloads, .browserToolbarProfile, .browserToolbarDevtools, .browserToolbarMedia,
        .browserToolbarZoomIn, .browserToolbarZoomOut, .browserToolbarBookmarks,
    ]

    /// The ink of an icon's Line drawing on the 24 grid: the union of its fill layers' outlines.
    private static func ink(_ name: IconName) -> CGRect? {
        guard let drawing = IconPack.bundled.drawing(for: name) else { return nil }
        let boxes = drawing.line.filter { $0.op == .fill }.compactMap { CGPath.icon($0.d)?.boundingBoxOfPath }
        guard let first = boxes.first else { return nil }
        return boxes.dropFirst().reduce(first) { union, box in union.union(box) }
    }

    @Test func everyToolbarGlyphHasTheBackArrowsInkBox() throws {
        let back = try #require(Self.ink(.browserToolbarBack))
        let keyline = max(back.width, back.height)
        for name in Self.toolbarGlyphs {
            let box = try #require(Self.ink(name), "\(name.rawValue) has no Line fill")
            #expect(abs(max(box.width, box.height) - keyline) < 0.1,
                    "\(name.rawValue)'s ink is \(box.size), the back arrow's long side is \(keyline)")
            #expect(abs(box.midX - 12) < 0.1 && abs(box.midY - 12) < 0.1,
                    "\(name.rawValue)'s ink is centered at \(box.midX), \(box.midY), not the grid's 12, 12")
        }
    }

    /// The puzzle Leo named: its ink box equals the back arrow's (it was 16 dp of Chrome's 20 against
    /// the arrow's 12, and 1 dp up and right of center).
    @Test func thePuzzleIsTheArrowsSize() throws {
        let puzzle = try #require(Self.ink(.browserToolbarExtensions))
        let back = try #require(Self.ink(.browserToolbarBack))
        #expect(abs(puzzle.width - back.width) < 0.1 && abs(puzzle.height - back.height) < 0.1, "puzzle \(puzzle.size), back \(back.size)")
    }

    /// One glyph side per density whose ink box is a tab icon's side (14 at Compact, 16 at level 1;
    /// Lawrence 2026-11-09), never wider than its button.
    @Test func theGlyphSideFollowsDensity() {
        let ratio = DensityTokens.toolbarGlyphInkRatio
        #expect(abs(DensityTokens.compact.toolbarGlyphSize * ratio - 14) < 0.001)
        #expect(abs(DensityTokens(id: "level1", name: "Level 1", level: 1).toolbarGlyphSize * ratio - 16) < 0.001)
        for preset in DensityPreset.allCases {
            let tokens = preset.tokens
            let icon = tokens.resolveGlyph(compact: 14, comfortable: 16, token: "iconSize")
            #expect(abs(tokens.toolbarGlyphSize * ratio - icon) < 0.001, "\(preset)")
            #expect(tokens.toolbarGlyphSize <= tokens.toolbarButtonSize, "\(preset)")
        }
    }

    /// The toolbar band and pane tab bar buttons draw their SF Symbols at the shared size and weight.
    @Test func bandButtonsReadTheSharedSymbolToken() {
        for preset in DensityPreset.allCases {
            DensityTokens.$scoped.withValue(preset.tokens) {
                let button = TitlebarBandButton(symbol: "chevron.left")
                let expected = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: Metrics.toolbarSymbolPointSize,
                                                                         weight: Metrics.toolbarSymbolWeight))
                #expect(button.image?.size == expected?.size, "\(preset): \(String(describing: button.image?.size))")
            }
        }
    }
}

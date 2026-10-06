import AppKit
import CmuxNextDesign
import CmuxNextIcons
import Testing
@testable import CmuxNextLayout

/// The drop overlay's card and new-workspace ghost draw the cmux icon
/// registry's split and workspace glyphs at the size of their label.
@MainActor @Suite struct DropOverlayRegistryIconTests {
    @Test func zonesNameTheirSplitIcon() {
        #expect(InsetCardRenderer.icon(.left) == .paneSplitLeft)
        #expect(InsetCardRenderer.icon(.right) == .paneSplitRight)
        #expect(InsetCardRenderer.icon(.top) == .paneSplitUp)
        #expect(InsetCardRenderer.icon(.bottom) == .paneSplitDown)
        #expect(InsetCardRenderer.icon(.center) == .workspace)
        #expect(InsetCardRenderer.icon(.column) == .column)
    }

    @Test func overlayGlyphsMatchTheirLabel() {
        let side = DropOverlayGlyph.side
        #expect(side == .iconRowSize(forLabelPointSize: Typography.bodyEmphasized.pointSize))
        let image = DropOverlayGlyph.image(.workspaceNew)
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: side, height: side))
    }
}

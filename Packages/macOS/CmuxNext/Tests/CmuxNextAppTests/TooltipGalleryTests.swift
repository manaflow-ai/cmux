import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The Tooltip Gallery (`debug.tooltipGallery`) draws every tooltip state with the real surface and content, in a
/// light, a dark and an accent theme, and a live toolbar whose buttons carry real themed tooltips.
@MainActor @Suite(.closesItsWindows, .serialized) struct TooltipGalleryTests {
    @Test func everyStateDrawsOnTheRealTooltipInEachTheme() throws {
        let gallery = TooltipGalleryWindow()
        gallery.show(themes: CmuxToastPlaygroundThemes(colors: [:]))
        let window = try #require(gallery.shownWindow)
        defer { window.closeAfterTest() }
        let view = try #require(window.contentView as? TooltipGalleryView)
        view.layoutSubtreeIfNeeded()
        #expect(view.sheets.map(\.title) == ["Light", "Dark", "Accent"])
        for sheet in view.sheets {
            #expect(sheet.tooltips.count == TooltipGallerySample.all.count)
            for (tooltip, sample) in zip(sheet.tooltips, TooltipGallerySample.all) {
                #expect(tooltip.content.text.stringValue == sample.text)
                #expect(tooltip.content.keycap?.label.stringValue == sample.shortcut)
                #expect(tooltip.surface.cornerRadius == TooltipPanel.radius)
                #expect((tooltip.surface.materialOverride == .opaque) == (sample.opaque || HoverSurfaceLook.current.isSolid), "\(sample.name)")
                // Sized as the panel sizes the same text and keys.
                let reference = TooltipContentView()
                reference.set(text: sample.text, shortcut: sample.shortcut)
                #expect(tooltip.intrinsicContentSize == reference.fittingSurfaceSize(maxWidth: TooltipPanel.maxWidth))
            }
            #expect(!sheet.liveButtons.isEmpty)
            for button in sheet.liveButtons {
                #expect(button.toolTip == nil)
                #expect(button.themedToolTip?.isEmpty == false)
            }
        }
    }
}

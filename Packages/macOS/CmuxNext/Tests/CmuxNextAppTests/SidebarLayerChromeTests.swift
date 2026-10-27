import AppKit
import CmuxNextDesign
@testable import CmuxNextFocusUI
@testable import CmuxNextSidebar
import Testing

/// Chrome-parity p03-rendering-112 (MQ-draw): the sidebar rail's ticks, the space bar's hover and
/// current-space chips, the profile avatar and the which-key body are layer properties set in
/// `updateLayer` (glyphs as ``ChromeTextLayer``s), never a `draw(_:)` backing store, so a selection
/// move or a hover recolors layers and repaints no pixels (cc/layers/solid_color_layer.h).
@MainActor @Suite(.serialized) struct SidebarLayerChromeTests {
    private static func section(_ ids: [String]) -> SidebarSection {
        SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)),
                       nodes: ids.map { .workspace(SidebarWorkspace(id: WorkspaceID($0), title: $0)) })
    }

    /// One pill layer per tick at the tick's rect; a selection move recolors, it adds no layer.
    @Test func railTicksAreOneLayerEach() throws {
        _ = NSApplication.shared
        let model = SidebarModel(sections: [Self.section(["a", "b", "c"])], activeWorkspaceID: WorkspaceID("a"))
        let rail = SidebarRailView()
        rail.frame = NSRect(x: 0, y: 0, width: 12, height: 600)
        rail.bind(model)
        #expect(rail.wantsUpdateLayer)
        rail.updateLayer()
        let ticks = rail.railLayout.ticks
        #expect(ticks.count == 3)
        #expect(rail.tickLayers.count == 3)
        for (tick, layer) in zip(ticks, rail.tickLayers) {
            #expect(layer.frame == tick.rect)
            #expect(layer.cornerRadius == tick.rect.height / 2)
            #expect(layer.backgroundColor != nil)
        }
        let selectedColor = try #require(rail.tickLayers.first?.backgroundColor)
        let plainColor = try #require(rail.tickLayers.last?.backgroundColor)
        #expect(selectedColor != plainColor, "the selected tick takes its own color")
        #expect(rail.layer?.contents == nil, "the rail draws no backing store")
    }

    /// A trailing-edge rail mirrors its ticks against the width.
    @Test func aTrailingRailMirrorsItsTickLayers() {
        _ = NSApplication.shared
        let model = SidebarModel(sections: [Self.section(["a"])], activeWorkspaceID: WorkspaceID("a"))
        let rail = SidebarRailView()
        rail.frame = NSRect(x: 0, y: 0, width: 12, height: 600)
        rail.bind(model)
        rail.hugsTrailingEdge = true
        rail.updateLayer()
        let tick = rail.railLayout.ticks[0]
        #expect(rail.tickLayers[0].frame.maxX == 12 - tick.rect.minX)
    }

    /// The bar's hover chip is a layer that shows under the hovered space and hides with no hover;
    /// the current-space chip is its own view's layer color.
    @Test func theSpaceBarChipsAreLayers() {
        _ = NSApplication.shared
        let model = SidebarModel()
        model.profiles = [
            SidebarProfile(id: ProfileKey("space-a"), name: "A", color: .red),
            SidebarProfile(id: ProfileKey("space-b"), name: "B", color: .blue),
        ]
        model.activeProfileID = model.profiles[0].id
        let bar = ProfileBarView(model: model)
        bar.frame = NSRect(x: 0, y: 0, width: 240, height: 28)
        bar.layoutSubtreeIfNeeded()
        bar.refresh()
        #expect(bar.wantsUpdateLayer)
        bar.updateLayer()
        #expect(bar.hoverFill.isHidden)
        bar.setHovered(1)
        bar.updateLayer()
        #expect(!bar.hoverFill.isHidden)
        #expect(bar.hoverFill.frame == bar.hoverChip?.rect)
        #expect(bar.hoverFill.backgroundColor != nil)
        bar.setHovered(nil)
        bar.updateLayer()
        #expect(bar.hoverFill.isHidden)

        #expect(bar.indicator.wantsUpdateLayer)
        bar.indicator.updateLayer()
        #expect(bar.indicator.layer?.backgroundColor != nil)
        #expect(bar.indicator.layer?.cornerRadius == SidebarStyle.rowCornerRadius)
    }

    /// Without a picture the avatar is the glass disc with its rim and the initial's glyph layer; a
    /// strength change recolors the disc.
    @Test func theAvatarIsADiscAndAGlyphLayer() throws {
        let view = SidebarAvatarView()
        view.frame = NSRect(x: 0, y: 0, width: 32, height: 32)
        view.updateLayer()
        #expect(view.disc.isHidden, "no avatar draws nothing")
        view.avatar = SidebarAvatar(name: "Lawrence", color: .blue)
        view.updateLayer()
        #expect(!view.disc.isHidden)
        #expect(view.disc.frame == view.circleFrame)
        #expect(view.disc.cornerRadius == view.circleFrame.height / 2)
        #expect(view.disc.borderWidth > 0, "the rim")
        #expect(!view.initial.isHidden)
        #expect(view.initial.string == view.avatar?.initial)
        #expect(view.picture.isHidden)
        let rest = try #require(view.disc.backgroundColor)
        view.isStrong = true
        view.updateLayer()
        let strong = try #require(view.disc.backgroundColor)
        #expect(strong.alpha > rest.alpha, "glass is more opaque under the pointer")
    }

    /// With a picture the disc shows the picture, decoded once per image: no glaze and no initial, and
    /// the same picture in a changed avatar keeps its decoded image.
    @Test func theAvatarPictureIsDecodedOnceAndShown() throws {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let view = SidebarAvatarView()
        view.frame = NSRect(x: 0, y: 0, width: 32, height: 32)
        view.avatar = .account(name: "Leo", email: "leo@cmux.com", imageData: png)
        view.updateLayer()
        let decoded = try #require(view.pictureImage, "the picture decodes")
        #expect(!view.disc.isHidden)
        #expect(!view.picture.isHidden)
        #expect(view.picture.contents != nil)
        #expect(view.picture.frame.size == view.circleFrame.size)
        #expect(view.glaze.isHidden, "a picture has no glaze")
        #expect(view.initial.isHidden, "a picture hides the initial")
        #expect(view.disc.backgroundColor == nil, "the picture fills the disc")
        view.avatar = .account(name: "Leo", email: "leo@manaflow.com", imageData: png)
        view.updateLayer()
        #expect(view.pictureImage === decoded, "the same picture is not decoded again")
        view.avatar = SidebarAvatar(name: "Leo")
        view.updateLayer()
        #expect(view.pictureImage == nil)
        #expect(view.picture.isHidden)
        #expect(!view.glaze.isHidden)
        #expect(!view.initial.isHidden)
    }

    /// A type-scale change reaches the cancel hint, made once in `init`: its glyphs take the font its
    /// frame is measured with.
    @Test func theWhichKeyHintTakesANewFontSize() throws {
        let saved = DesignSettings.shared.overrides[.chromeFontSize]
        defer { DesignSettings.shared.setOverride(.chromeFontSize, saved) }
        DesignSettings.shared.setOverride(.chromeFontSize, nil)
        let body = WhichKeyView()
        body.update(prefix: ["Space"], rows: [WhichKeyRow(key: "w", title: "Window", isEnabled: true)])
        body.frame = NSRect(origin: .zero, size: body.size(fitting: 600))
        body.updateLayer()
        let before = Typography.caption
        #expect(body.hintLayer.font == before)
        DesignSettings.shared.setOverride(.chromeFontSize, 16)
        let after = Typography.caption
        try #require(after.pointSize != before.pointSize, "the override changes the caption size")
        body.updateLayer()
        #expect(body.hintLayer.font == after, "the hint draws in the font its frame is measured with")
        #expect(body.hintLayer.frame.height == ceil(after.ascender - after.descender))
    }

    /// The which-key body is a layer per cap, hint and title, rebuilt on an update.
    @Test func theWhichKeyBodyIsLayers() {
        let body = WhichKeyView()
        #expect(body.wantsUpdateLayer)
        body.update(prefix: ["Space"], rows: [
            WhichKeyRow(key: "w", title: "Window", isEnabled: true),
            WhichKeyRow(key: "t", title: "Tab", isEnabled: false),
        ])
        body.frame = NSRect(origin: .zero, size: body.size(fitting: 600))
        body.updateLayer()
        let sublayers = body.layer?.sublayers ?? []
        #expect(sublayers.compactMap { $0 as? ChromeFillLayer }.count == 3, "one fill per cap: the prefix and two keys")
        #expect(sublayers.compactMap { $0 as? ChromeTextLayer }.count == 3, "the hint and two titles")
        body.update(prefix: [], rows: [WhichKeyRow(key: "q", title: "Quit", isEnabled: true)])
        let rebuilt = body.layer?.sublayers ?? []
        #expect(rebuilt.compactMap { $0 as? ChromeFillLayer }.count == 1)
        #expect(rebuilt.compactMap { $0 as? ChromeTextLayer }.count == 2)
        #expect(body.layer?.contents == nil)
    }
}

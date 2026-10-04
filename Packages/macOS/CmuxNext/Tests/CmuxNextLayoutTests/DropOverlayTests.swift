import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextLayout

/// Drop overlay styles: the variant list, its tunable, every renderer, the
/// pure geometry, and that layout tunables default to the old literals.
@MainActor
@Suite struct DropOverlayTests {
    @Test func offersThirteenStylesWithTheOutlineAsTheDefault() {
        #expect(DropOverlayStyle.allCases.count == 13)
        #expect(DropOverlayTunables.style.defaultValue == .outline)
        guard case .choice(let options) = DropOverlayTunables.style.descriptor.kind else {
            Issue.record("style is not a choice")
            return
        }
        #expect(options.map(\.value) == DropOverlayStyle.allCases.map(\.rawValue))
        #expect(Set(options.map(\.title)).count == options.count)
        #expect(DropOverlayStyle.allCases.filter(\.usesGlass) == [.glassFill, .glassOutline, .insetCard, .splitPreview, .tabGhost, .morph])
    }

    @Test func styleTunableSelectsTheVariant() {
        let store = TunableStore()
        store.register(LayoutTunables.all)
        store.activate(file: nil)
        #expect(DropOverlayTunables.style.value(in: store) == .outline)
        store.set("drop.overlay.style", .choice("splitPreview"))
        #expect(DropOverlayTunables.style.value(in: store) == .splitPreview)
        #expect(store.set("drop.overlay.style", .choice("sparkles")) == nil)
        #expect(DropOverlayTunables.style.value(in: store) == .splitPreview)
    }

    @Test func everyStyleHasARendererThatDrawsAFrame() {
        let frame = DropOverlayFrame(target: CGRect(x: 10, y: 10, width: 200, height: 120),
                                     region: CGRect(x: 10, y: 10, width: 400, height: 120), zone: .left,
                                     bounds: CGRect(x: 0, y: 0, width: 600, height: 400), cornerRadius: 8,
                                     label: "Split Left", showsLabel: true)
        for style in DropOverlayStyle.allCases {
            let renderer = DropOverlayRenderers.make(style, material: .opaque)
            #expect(renderer.style == style)
            renderer.view.frame = frame.bounds
            renderer.update(frame)
            renderer.applyTheme()
            if style.usesGlass {
                #expect(renderer.material == .opaque, "\(style) must follow the pinned material")
            } else {
                #expect(renderer.material == nil, "\(style) draws no glass")
            }
        }
    }

    /// tab-dnd (Lawrence 2026-10-04: "i dont like solid thing, id rather
    /// just draw the border around where it will be dropped"): the default
    /// draws a border exactly around the drop rect, no fill, and needs no
    /// frame clock (the compositor animates it).
    @Test func theDefaultIsABorderExactlyAroundTheDropRect() throws {
        let plane = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let highlight = DropHighlightView(material: .opaque)
        plane.addSubview(highlight)
        let rect = CGRect(x: 0, y: 0, width: 300, height: 400)
        let needsClock = highlight.show(rect, region: CGRect(x: 0, y: 0, width: 600, height: 400), zone: .left, text: "Split Left",
                                        inset: 0, cornerRadius: 6, pointer: .zero, animated: true)
        #expect(highlight.style == .outline)
        #expect(!needsClock, "the outline moves on the compositor, not on a frame clock")
        #expect(highlight.targetRect == rect)
        #expect(highlight.frame == plane.bounds)
        let outline = try #require(highlight.outline)
        #expect(outline.ringFrame == rect)
        #expect(outline.ringWidth == 2)
        #expect(!outline.ringHasFill)
        #expect(!outline.showsChip, "a target the drop takes shows the border alone")
        // A move to the next target is one compositor animation to its rect.
        let next = CGRect(x: 300, y: 0, width: 300, height: 400)
        #expect(!highlight.show(next, region: next, zone: .right, text: "Split Right", inset: 0, cornerRadius: 6, pointer: .zero,
                                animated: true))
        #expect(outline.ringFrame == next)
        highlight.setNote("No room", refused: true)
        #expect(highlight.isRefused)
        #expect(outline.showsChip)
        _ = highlight.hide(animated: false)
        #expect(!highlight.isShowing)
        #expect(outline.ringOpacity == 0)
    }

    @Test func splitPreviewShowsBothPanesAtTheirFinalSizes() {
        let region = CGRect(x: 0, y: 0, width: 400, height: 200)
        let left = DropOverlayGeometry.splitPreview(region: region, zone: .left, gap: 8)
        #expect(left.incoming == CGRect(x: 0, y: 0, width: 196, height: 200))
        #expect(left.existing == CGRect(x: 204, y: 0, width: 196, height: 200))
        let bottom = DropOverlayGeometry.splitPreview(region: region, zone: .bottom, gap: 0)
        #expect(bottom.incoming == CGRect(x: 0, y: 100, width: 400, height: 100))
        #expect(bottom.existing == CGRect(x: 0, y: 0, width: 400, height: 100))
        #expect(DropOverlayGeometry.splitPreview(region: region, zone: .center, gap: 8).existing == nil)
    }

    @Test func insertionLineSitsWhereTheDividerOrStripAppears() {
        let region = CGRect(x: 0, y: 0, width: 400, height: 200)
        let vertical = DropOverlayGeometry.insertionLine(region: region, zone: .right, width: 4, length: 0.5)
        #expect(vertical == CGRect(x: 198, y: 50, width: 4, height: 100))
        let horizontal = DropOverlayGeometry.insertionLine(region: region, zone: .top, width: 4, length: 1)
        #expect(horizontal == CGRect(x: 0, y: 98, width: 400, height: 4))
        let strip = DropOverlayGeometry.insertionLine(region: region, zone: .center, width: 4, length: 0.5)
        #expect(strip.minY == 4 && strip.width == 200)
    }

    @Test func glowCardPillAndMorphGeometry() {
        #expect(DropOverlayGeometry.glowEdges(.left) == [.minXEdge])
        #expect(DropOverlayGeometry.glowEdges(.center).count == 4)
        let target = CGRect(x: 0, y: 0, width: 300, height: 200)
        #expect(DropOverlayGeometry.band(target, edge: .maxXEdge, depth: 50) == CGRect(x: 250, y: 0, width: 50, height: 200))
        #expect(DropOverlayGeometry.insetCard(target: target, fraction: 0.5, maxWidth: 120, height: 40)
            == CGRect(x: 90, y: 80, width: 120, height: 40))
        #expect(DropOverlayGeometry.tabPill(target: target, width: 500, height: 24, inset: 2) == CGRect(x: 2, y: 2, width: 296, height: 24))
        #expect(DropOverlayGeometry.morphStart(pointer: CGPoint(x: 100, y: 100), width: 60) == CGRect(x: 70, y: 80, width: 60, height: 40))
    }

    @Test func layoutTunablesDefaultToTheOldLiterals() {
        let style = LayoutStyle()
        #expect(LayoutTunables.dropEdgeFraction.defaultValue == style.dropEdgeFraction)
        #expect(LayoutTunables.dropEdgeMinimum.defaultValue == style.dropEdgeRange.lowerBound)
        #expect(LayoutTunables.dropEdgeMaximum.defaultValue == style.dropEdgeRange.upperBound)
        #expect(LayoutTunables.newColumnDropWidth.defaultValue == style.newColumnDropWidth)
        #expect(LayoutTunables.inactivePaneDimming.defaultValue == style.inactivePaneDimming)
        #expect(LayoutTunables.minimumContentWidth.defaultValue == style.minimumPaneContentSize.width)
        #expect(LayoutTunables.minimumContentHeight.defaultValue == style.minimumPaneContentSize.height)
        let keys = LayoutTunables.all.map(\.key)
        #expect(Set(keys).count == keys.count)
        for descriptor in LayoutTunables.all {
            #expect(descriptor.clamp(descriptor.defaultValue) == descriptor.defaultValue, "\(descriptor.key)")
        }
    }
}

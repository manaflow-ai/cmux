@testable import CmuxNextDesign
import CoreGraphics
import Testing

/// Background art covers the whole window at every size (aspect fill; Leo, 2026-10-19: "it
/// should resize better... it is able to fill more"), and within that keeps its subject whole
/// where it can be seen: each painting names its subject (`subject` in art/manifest.json), and the
/// art zooms or slides so that box lies clear of the sidebar and a docked agent chat (Leo,
/// 2026-10-18). Before, art shrank over a blurred fill to keep a subject whole, and a side render
/// (a tall work beside a darkened fill of itself) left the left of the window dark.
@MainActor @Suite struct BackdropArtPlacementTests {
    static let image = CGSize(width: 1600, height: 1000)

    /// A painting whose subject is `box` (minX, minY, maxX, maxY), with the painting only in
    /// `panel` of the image for a side render.
    static func art(_ box: (Double, Double, Double, Double), panel: (Double, Double, Double, Double)? = nil) -> BackdropArtMetadata {
        BackdropArtMetadata(focalAnchor: .center, tone: .dark, dominantPalette: [], quietZone: .init(x: 0, y: 0, width: 0, height: 0),
                            subjectBox: .init(minX: box.0, minY: box.1, maxX: box.2, maxY: box.3),
                            panel: panel.map { BackdropSubjectBox(minX: $0.0, minY: $0.1, maxX: $0.2, maxY: $0.3) })
    }

    /// The subject's frame in the view, in points from the bottom-left (as the placement's frame).
    static func subjectFrame(_ placement: BackdropArtPlacement, _ metadata: BackdropArtMetadata) -> CGRect {
        let c = placement.contentsRect, f = placement.frame, box = metadata.subject
        // Image fraction → view point, through the shown part of the image.
        func x(_ u: Double) -> Double { f.minX + (u - c.minX) / c.width * f.width }
        func y(_ v: Double) -> Double { f.minY + ((1 - v) - c.minY) / c.height * f.height }
        return CGRect(x: x(box.minX), y: y(box.maxY), width: x(box.maxX) - x(box.minX), height: y(box.minY) - y(box.maxY))
    }

    /// The art covers the whole view, unstretched, showing only the painting (never a side
    /// render's blurred fill).
    static func checkCovers(_ placement: BackdropArtPlacement, view: CGSize, panel: BackdropSubjectBox? = nil,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        let c = placement.contentsRect
        #expect(c.minX >= -1e-9 && c.minY >= -1e-9 && c.maxX <= 1 + 1e-9 && c.maxY <= 1 + 1e-9,
                "the shown part \(c) leaves the image", sourceLocation: sourceLocation)
        #expect(placement.frame == CGRect(origin: .zero, size: view),
                "the art's frame \(placement.frame) does not cover the view \(view)", sourceLocation: sourceLocation)
        // The frame and the part of the image shown have one aspect: the art is never stretched.
        let shown = c.width * image.width / (c.height * image.height)
        #expect(abs(shown - view.width / view.height) < 0.01, "the art is stretched", sourceLocation: sourceLocation)
        if let panel {
            // contentsRect counts from the bottom; the panel from the top.
            #expect(c.minX >= panel.minX - 1e-6 && c.maxX <= panel.maxX + 1e-6
                    && 1 - c.maxY >= panel.minY - 1e-6 && 1 - c.minY <= panel.maxY + 1e-6,
                    "the shown part \(c) leaves the painting \(panel) for the blurred fill", sourceLocation: sourceLocation)
        }
    }

    @Test func aWindowOfThePaintingsOwnShapeShowsAllOfIt() {
        let view = CGSize(width: 1440, height: 900)
        let placement = Self.art((0.6, 0.2, 0.8, 0.7)).placement(forViewSize: view, imageSize: Self.image)
        #expect(placement.contentsRect == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(placement.frame == CGRect(origin: .zero, size: view))
        #expect(placement.keepsSubject)
    }

    @Test func aSubjectOffCenterStaysInAWideShortWindow() {
        // A 21:9 window crops the 16:10 art top and bottom; a subject low in the picture stays in.
        let view = CGSize(width: 2520, height: 1080)
        let metadata = Self.art((0.2, 0.7, 0.4, 0.95))
        let placement = metadata.placement(forViewSize: view, imageSize: Self.image)
        Self.checkCovers(placement, view: view)
        let subject = Self.subjectFrame(placement, metadata)
        #expect(subject.minY >= -0.5 && subject.maxY <= view.height + 0.5, "the subject \(subject) is cut top or bottom")
        #expect(placement.keepsSubject)
    }

    @Test func theSubjectMovesClearOfTheAgentChatColumn() {
        // Sidebar and agent chat over the left 660 points: the face the old fixed point put
        // under them comes out to the right.
        let view = CGSize(width: 1512, height: 945)
        let visible = BackdropVisibleSpan.uncovered(width: view.width, by: [0...240, 240...660])
        #expect(abs(visible.minX - 660 / 1512) < 1e-9 && visible.maxX == 1)
        let metadata = Self.art((0.3, 0.1, 0.5, 0.6))
        let placement = metadata.placement(forViewSize: view, imageSize: Self.image, visible: visible)
        Self.checkCovers(placement, view: view)
        let subject = Self.subjectFrame(placement, metadata)
        #expect(subject.minX >= 660 - 0.5 && subject.maxX <= view.width + 0.5, "the subject \(subject) is under the panes")
        #expect(placement.keepsSubject)
    }

    /// The review's case (#21709): a subject that fits the span at the cover scale but not while
    /// the art covers the window used to shrink the art over a blurred fill, leaving the window's
    /// edges unpainted. Now the art still covers the window, as near the span as its edges allow.
    @Test func aSubjectThatFitsOnlyOffTheCoverStillCoversTheWindow() {
        let view = CGSize(width: 1512, height: 945)
        let visible = BackdropVisibleSpan.uncovered(width: view.width, by: [0...240, 240...660])
        let metadata = Self.art((0.25, 0.15, 0.7, 0.9))
        let placement = metadata.placement(forViewSize: view, imageSize: Self.image, visible: visible)
        Self.checkCovers(placement, view: view)
        #expect(!placement.keepsSubject)
    }

    @Test func aSubjectTooWideForTheVisibleSpanCoversTheWindowAroundIt() {
        let view = CGSize(width: 1512, height: 945)
        let visible = BackdropVisibleSpan.uncovered(width: view.width, by: [0...660])
        let placement = Self.art((0.1, 0.2, 0.75, 0.8)).placement(forViewSize: view, imageSize: Self.image, visible: visible)
        Self.checkCovers(placement, view: view)
        #expect(!placement.keepsSubject)
    }

    /// A side render: the painting in the right 45% of the image, a blurred, darkened fill of it
    /// on the left. The window covers itself with the painting alone, at every shape, and a
    /// portrait's subject that cannot show whole centers on its upper third (the face).
    @Test(arguments: [CGSize(width: 1512, height: 945), CGSize(width: 2560, height: 1080), CGSize(width: 900, height: 1300),
                      CGSize(width: 800, height: 500)])
    func aSideRenderCoversTheWindowWithItsPaintingAlone(view: CGSize) {
        let panel = BackdropSubjectBox(minX: 0.55, minY: 0, maxX: 1, maxY: 1)
        let metadata = Self.art((0.57, 0.04, 0.98, 0.7), panel: (0.55, 0, 1, 1))
        let visible = BackdropVisibleSpan.uncovered(width: view.width, by: [0...240])
        let placement = metadata.placement(forViewSize: view, imageSize: Self.image, visible: visible)
        Self.checkCovers(placement, view: view, panel: panel)
        if !placement.keepsSubject {
            let subject = Self.subjectFrame(placement, metadata)
            // The point a third of the way down the subject, from the view's top, sits mid-view
            // unless the painting's top or bottom edge stops it there.
            let third = view.height - (subject.maxY - subject.height / 3)
            let c = placement.contentsRect
            let atEdge = abs(c.maxY - 1) < 1e-6 || abs(c.minY) < 1e-6
            #expect(abs(third - view.height / 2) < 1 || atEdge, "the portrait's upper third is at \(third) in \(view)")
        }
    }

    @Test func aSubjectFarTooWideCoversTheWindowAroundItsCenter() {
        // No thin strip in a sea of blur: the art covers the window around the subject's center.
        let view = CGSize(width: 756, height: 945)
        let visible = BackdropVisibleSpan.uncovered(width: view.width, by: [0...252])
        let placement = Self.art((0.0, 0.1, 1.0, 0.9)).placement(forViewSize: view, imageSize: Self.image, visible: visible)
        Self.checkCovers(placement, view: view)
        #expect(!placement.keepsSubject)
    }

    @Test func aNarrowGapBetweenColumnsIsNoPlaceForASubject() {
        #expect(BackdropVisibleSpan.uncovered(width: 1000, by: [0...800]) == .whole)
        #expect(BackdropVisibleSpan.uncovered(width: 1000, by: []) == .whole)
        // Columns past the edge, overlapping or reversed are clamped, never trapped on.
        let span = BackdropVisibleSpan.uncovered(width: 1000, by: [-50...200, 150...300, 1200...1400])
        #expect(span.minX == 0.3 && span.maxX == 1)
        #expect(BackdropVisibleSpan.uncovered(width: 0, by: [0...10]) == .whole)
    }

    @Test func artThatNamesOnlyAFocalPointKeepsASmallBoxAroundIt() {
        let metadata = BackdropArtMetadata(focalAnchor: .init(x: 0.8, y: 0.45), tone: .dark, dominantPalette: [],
                                           quietZone: .init(x: 0, y: 0, width: 0, height: 0))
        let box = metadata.subject
        #expect(abs(box.center.x - 0.8) < 1e-9 && abs(box.center.y - 0.45) < 1e-9)
        let placement = metadata.placement(forViewSize: CGSize(width: 900, height: 900), imageSize: Self.image)
        let subject = Self.subjectFrame(placement, metadata)
        #expect(subject.minX >= -0.5 && subject.maxX <= 900.5, "the focal point's box \(subject) is off the window")
    }

    @Test func degenerateSizesShowTheWholeImage() {
        let metadata = Self.art((0.4, 0.4, 0.6, 0.6))
        #expect(metadata.placement(forViewSize: .zero, imageSize: Self.image) == .whole(.zero))
        #expect(metadata.placement(forViewSize: CGSize(width: 10, height: 10), imageSize: .zero).contentsRect == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Every painting in the catalog, in the window shapes people use, beside a sidebar and an
    /// agent chat: the subject stays whole and visible, measured, for as many as the cover allows
    /// (`scripts/cmux-next/art/framing_sheet.py` prints the same counts and draws them). A side
    /// render's subject is its whole tall painting, which a wide window crops.
    @Test(arguments: [
        (CGSize(width: 1512, height: 945), [ClosedRange<CGFloat>](), 74),
        (CGSize(width: 1512, height: 945), [0...240, 240...660], 15),
        (CGSize(width: 2560, height: 1080), [0...240, 240...660], 16),
    ])
    func everyPaintingKeepsItsSubjectInTheCommonLayouts(view: CGSize, covered: [ClosedRange<CGFloat>], least: Int) {
        let visible = BackdropVisibleSpan.uncovered(width: view.width, by: covered)
        var kept = 0
        for art in BackdropArt.allCases {
            let box = art.metadata.subject
            #expect(box.minX < box.maxX && box.minY < box.maxY, "\(art) has an empty subject")
            let placement = art.metadata.placement(forViewSize: view, imageSize: Self.image, visible: visible)
            // Kept means kept: the subject's frame lies in the visible span and the window.
            let subject = Self.subjectFrame(placement, art.metadata)
            let inside = subject.minX >= visible.minX * view.width - 1 && subject.maxX <= visible.maxX * view.width + 1
                && subject.minY >= -1 && subject.maxY <= view.height + 1
            #expect(placement.keepsSubject == inside, "\(art) says kept \(placement.keepsSubject) with its subject at \(subject)")
            if inside { kept += 1 }
        }
        #expect(kept >= least, "only \(kept) of \(BackdropArt.allCases.count) paintings keep their subject in view")
    }

    /// Every painting covers the window in every common shape, with and without the sidebar and
    /// an agent chat: no letterbox, no unpainted edge, no side render's dark fill, never
    /// stretched (Leo's report, 2026-10-19: the left of the window went dark beside a portrait).
    @Test(arguments: [
        CGSize(width: 2560, height: 1080), CGSize(width: 1512, height: 945), CGSize(width: 900, height: 1300),
        CGSize(width: 800, height: 500), CGSize(width: 756, height: 945), CGSize(width: 2672, height: 1522),
    ])
    func everyPaintingCoversTheWindow(view: CGSize) {
        for covered in [[], [0...240], [0...240, 240...660]] as [[ClosedRange<CGFloat>]] {
            let visible = BackdropVisibleSpan.uncovered(width: view.width, by: covered)
            for art in BackdropArt.allCases {
                let placement = art.metadata.placement(forViewSize: view, imageSize: Self.image, visible: visible)
                Self.checkCovers(placement, view: view, panel: art.metadata.panel)
            }
        }
    }

    /// The catalog's side renders name their painting: a work whose image has a blurred fill
    /// beside it and no panel would cover the window with that fill (Wanderer above the Sea of Fog
    /// and Girl with a Pearl Earring were side renders when Leo reported it).
    @Test func sideRendersNameTheirPainting() throws {
        for art in [BackdropArt.friedrichWanderer, .vermeerPearlEarring, .millaisJoanOfArc] {
            let panel = try #require(art.metadata.panel, "\(art) has no panel")
            #expect(panel.minX > 0.2 && panel.maxX == 1 && panel.minY == 0 && panel.maxY == 1)
            #expect(art.metadata.subject.minX >= panel.minX - 0.05, "\(art)'s subject lies in its fill")
        }
    }
}

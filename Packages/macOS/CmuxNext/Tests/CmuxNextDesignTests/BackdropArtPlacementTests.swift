@testable import CmuxNextDesign
import CoreGraphics
import Testing

/// Background art keeps its subject whole where it can be seen: each painting names its subject
/// (`subject` in art/manifest.json), and the art zooms, slides or shrinks so that box lies clear
/// of the sidebar and a docked agent chat (Leo, 2026-10-18). Before, every wide painting framed
/// the same fixed point (0.5, 0.45), so faces landed under the agent pane or off the window.
@MainActor @Suite struct BackdropArtPlacementTests {
    static let image = CGSize(width: 1600, height: 1000)

    /// A painting whose subject is `box` (minX, minY, maxX, maxY).
    static func art(_ box: (Double, Double, Double, Double)) -> BackdropArtMetadata {
        BackdropArtMetadata(focalAnchor: .center, tone: .dark, dominantPalette: [], quietZone: .init(x: 0, y: 0, width: 0, height: 0),
                            subjectBox: .init(minX: box.0, minY: box.1, maxX: box.2, maxY: box.3))
    }

    /// The subject's frame in the view, in points from the bottom-left (as the placement's frame).
    static func subjectFrame(_ placement: BackdropArtPlacement, _ metadata: BackdropArtMetadata) -> CGRect {
        let c = placement.contentsRect, f = placement.frame, box = metadata.subject
        // Image fraction → view point, through the shown part of the image.
        func x(_ u: Double) -> Double { f.minX + (u - c.minX) / c.width * f.width }
        func y(_ v: Double) -> Double { f.minY + ((1 - v) - c.minY) / c.height * f.height }
        return CGRect(x: x(box.minX), y: y(box.maxY), width: x(box.maxX) - x(box.minX), height: y(box.minY) - y(box.maxY))
    }

    static func checkSane(_ placement: BackdropArtPlacement, view: CGSize, sourceLocation: SourceLocation = #_sourceLocation) {
        let c = placement.contentsRect
        #expect(c.minX >= -1e-9 && c.minY >= -1e-9 && c.maxX <= 1 + 1e-9 && c.maxY <= 1 + 1e-9,
                "the shown part \(c) leaves the image", sourceLocation: sourceLocation)
        #expect(CGRect(origin: .zero, size: view).insetBy(dx: -0.5, dy: -0.5).contains(placement.frame),
                "the art's frame \(placement.frame) leaves the view", sourceLocation: sourceLocation)
        // The frame and the part of the image shown have one aspect: the art is never stretched.
        let shown = c.width * image.width / (c.height * image.height)
        #expect(abs(shown - placement.frame.width / placement.frame.height) < 0.01, "the art is stretched", sourceLocation: sourceLocation)
    }

    @Test func aWindowOfThePaintingsOwnShapeShowsAllOfIt() {
        let view = CGSize(width: 1440, height: 900)
        let placement = Self.art((0.6, 0.2, 0.8, 0.7)).placement(forViewSize: view, imageSize: Self.image)
        #expect(placement.contentsRect == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(placement.frame == CGRect(origin: .zero, size: view))
        #expect(!placement.fills && placement.keepsSubject)
    }

    @Test func aSubjectOffCenterStaysInAWideShortWindow() {
        // A 21:9 window crops the 16:10 art top and bottom; a subject low in the picture stays in.
        let view = CGSize(width: 2520, height: 1080)
        let metadata = Self.art((0.2, 0.7, 0.4, 0.95))
        let placement = metadata.placement(forViewSize: view, imageSize: Self.image)
        Self.checkSane(placement, view: view)
        let subject = Self.subjectFrame(placement, metadata)
        #expect(subject.minY >= -0.5 && subject.maxY <= view.height + 0.5, "the subject \(subject) is cut top or bottom")
        #expect(placement.keepsSubject && !placement.fills)
    }

    @Test func theSubjectMovesClearOfTheAgentChatColumn() {
        // Sidebar and agent chat over the left 660 points: the face the old fixed point put
        // under them comes out to the right.
        let view = CGSize(width: 1512, height: 945)
        let visible = BackdropVisibleSpan.uncovered(width: view.width, by: [0...240, 240...660])
        #expect(abs(visible.minX - 660 / 1512) < 1e-9 && visible.maxX == 1)
        let metadata = Self.art((0.3, 0.1, 0.5, 0.6))
        let placement = metadata.placement(forViewSize: view, imageSize: Self.image, visible: visible)
        Self.checkSane(placement, view: view)
        let subject = Self.subjectFrame(placement, metadata)
        #expect(subject.minX >= 660 - 0.5 && subject.maxX <= view.width + 0.5, "the subject \(subject) is under the panes")
        #expect(placement.keepsSubject)
    }

    /// The review's case (#21709): Böcklin's Isle of the Dead, whose subject fits the span at the
    /// cover scale but not while the art covers the window, slides right, under the panes, instead
    /// of staying under them.
    @Test func aSubjectThatFitsOnlyOffTheCoverSlidesClearOfTheColumns() {
        let view = CGSize(width: 1512, height: 945)
        let visible = BackdropVisibleSpan.uncovered(width: view.width, by: [0...240, 240...660])
        let metadata = BackdropArt.bocklinIsleOfTheDead.metadata
        let placement = metadata.placement(forViewSize: view, imageSize: Self.image, visible: visible)
        Self.checkSane(placement, view: view)
        let subject = Self.subjectFrame(placement, metadata)
        #expect(placement.keepsSubject && placement.fills)
        #expect(subject.minX >= 660 - 0.5 && subject.maxX <= view.width + 0.5, "the subject \(subject) stayed under the panes")
    }

    @Test func aSubjectTooWideForTheVisibleSpanShrinksOverTheFill() {
        let view = CGSize(width: 1512, height: 945)
        let visible = BackdropVisibleSpan.uncovered(width: view.width, by: [0...660])
        let metadata = Self.art((0.1, 0.2, 0.75, 0.8))
        let placement = metadata.placement(forViewSize: view, imageSize: Self.image, visible: visible)
        Self.checkSane(placement, view: view)
        #expect(placement.fills, "the art covers the window and cuts its subject")
        let subject = Self.subjectFrame(placement, metadata)
        #expect(subject.minX >= 660 - 0.5 && subject.maxX <= view.width + 0.5, "the subject \(subject) is under the panes")
    }

    @Test func aSubjectFarTooWideCoversTheWindowAroundItsCenter() {
        // Past the least shrink the art covers the window again: no thin strip in a sea of blur.
        let view = CGSize(width: 756, height: 945)
        let visible = BackdropVisibleSpan.uncovered(width: view.width, by: [0...252])
        let placement = Self.art((0.0, 0.1, 1.0, 0.9)).placement(forViewSize: view, imageSize: Self.image, visible: visible)
        Self.checkSane(placement, view: view)
        #expect(!placement.fills && !placement.keepsSubject)
        #expect(placement.frame == CGRect(origin: .zero, size: view))
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
    /// agent chat: the subject stays whole and visible, measured, for all but a few very wide
    /// works (`scripts/cmux-next/art/framing_sheet.py` prints the same counts and draws them).
    @Test(arguments: [
        (CGSize(width: 1512, height: 945), [ClosedRange<CGFloat>](), 174),
        (CGSize(width: 1512, height: 945), [0...240, 240...660], 172),
        (CGSize(width: 2560, height: 1080), [0...240, 240...660], 174),
    ])
    func everyPaintingKeepsItsSubjectInTheCommonLayouts(view: CGSize, covered: [ClosedRange<CGFloat>], least: Int) {
        let visible = BackdropVisibleSpan.uncovered(width: view.width, by: covered)
        var kept = 0
        for art in BackdropArt.allCases {
            let box = art.metadata.subject
            #expect(box.minX < box.maxX && box.minY < box.maxY, "\(art) has an empty subject")
            let placement = art.metadata.placement(forViewSize: view, imageSize: Self.image, visible: visible)
            Self.checkSane(placement, view: view)
            // Kept means kept: the subject's frame lies in the visible span and the window.
            let subject = Self.subjectFrame(placement, art.metadata)
            let inside = subject.minX >= visible.minX * view.width - 1 && subject.maxX <= visible.maxX * view.width + 1
                && subject.minY >= -1 && subject.maxY <= view.height + 1
            #expect(placement.keepsSubject == inside, "\(art) says kept \(placement.keepsSubject) with its subject at \(subject)")
            if inside { kept += 1 }
        }
        #expect(kept >= least, "only \(kept) of \(BackdropArt.allCases.count) paintings keep their subject in view")
    }
}

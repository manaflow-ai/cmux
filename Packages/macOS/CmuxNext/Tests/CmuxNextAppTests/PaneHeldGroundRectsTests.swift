import AppKit
@testable import CmuxNextLayout
import Testing

/// SPLIT OPEN CHAT (review of #40665): `PaneClipView.heldGroundRects` says which parts of a pane show its held
/// content's own ground: the parts the content does not cover while its pane is still larger than its rest (the pane a
/// split halves). Only the "below" case ran in a test (`ChatSplitShowsNoWindowColourTests`). Each case here is one
/// place the held content can have in its pane, in the pane's flipped space (minY is the top).
///
/// A screen at 2x places a spring's frames on half points, so the last frames of a split leave a part 0.5 pt (one
/// pixel) wide or high. That part is ground too: without it the far edge shows a line of the window's color, one
/// pixel thick, for those frames.
@MainActor @Suite struct PaneHeldGroundRectsTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let content: CGRect
        var header: CGFloat = 0
        var footer: CGFloat = 0
        var leading: CGFloat = 0
        let grounds: [CGRect]
        var testDescription: String { name }
    }

    /// The pane's clip: 800 x 600 pt.
    nonisolated static let clip = CGRect(x: 0, y: 0, width: 800, height: 600)

    nonisolated static func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect { CGRect(x: x, y: y, width: width, height: height) }

    nonisolated static let places: [Case] = [
        Case(name: "the content covers the pane: no ground", content: clip, header: 38, grounds: []),
        Case(name: "the content is larger than the pane (a new pane that grows in): no ground", content: rect(-400, 0, 1200, 600), grounds: []),
        Case(name: "a part smaller than any pixel (float noise): no ground", content: rect(0, 0, 799.999, 599.999), grounds: []),
        // Beyond one edge (Split Down and Split Up).
        Case(name: "below the content, tabs on top", content: rect(0, 0, 800, 299), header: 38, grounds: [rect(0, 299, 800, 301)]),
        Case(name: "below the content, under its strip at the bottom", content: rect(0, 0, 800, 299), footer: 38, grounds: [rect(0, 299, 800, 301)]),
        Case(name: "below the content, its vertical list's column stays clear", content: rect(0, 0, 800, 299), leading: 44, grounds: [rect(44, 299, 756, 301)]),
        Case(name: "above the content", content: rect(0, 301, 800, 299), header: 38, grounds: [rect(0, 0, 800, 301)]),
        Case(name: "above the content, its vertical list's column stays clear", content: rect(0, 301, 800, 299), leading: 44, grounds: [rect(44, 0, 756, 301)]),
        // Beside it (Split Right and Split Left).
        Case(name: "right of the content, no tabs above it (a hidden strip)", content: rect(0, 0, 399, 600), grounds: [rect(399, 0, 401, 600)]),
        Case(name: "right of the content, the rows of its strip on top stay clear", content: rect(0, 0, 399, 600), header: 38, grounds: [rect(399, 38, 401, 562)]),
        Case(name: "right of the content, the rows of its strip at the bottom stay clear", content: rect(0, 0, 399, 600), footer: 38, grounds: [rect(399, 0, 401, 562)]),
        Case(name: "left of the content", content: rect(401, 0, 399, 600), grounds: [rect(0, 0, 401, 600)]),
        Case(name: "left of the content, the rows of its strip stay clear", content: rect(401, 0, 399, 600), header: 38, grounds: [rect(0, 38, 401, 562)]),
        Case(name: "left of the content and its vertical list", content: rect(401, 0, 399, 600), leading: 44, grounds: [rect(0, 0, 401, 600)]),
        // On two axes: the part beside takes the corner.
        Case(name: "below and right", content: rect(0, 0, 399, 299), header: 38, grounds: [rect(0, 299, 399, 301), rect(399, 38, 401, 562)]),
        Case(name: "below and left, a strip at the bottom", content: rect(401, 0, 399, 299), footer: 38, grounds: [rect(401, 299, 399, 301), rect(0, 0, 401, 600)]),
        Case(name: "above and right", content: rect(0, 301, 399, 299), header: 38, grounds: [rect(0, 0, 399, 301), rect(399, 0, 401, 600)]),
        Case(name: "above and left, a strip at the bottom", content: rect(401, 301, 399, 299), footer: 38, grounds: [rect(401, 0, 399, 301), rect(0, 0, 401, 562)]),
        Case(name: "below and right, a vertical list", content: rect(0, 0, 399, 299), leading: 44, grounds: [rect(44, 299, 355, 301), rect(399, 0, 401, 600)]),
        // Content with no area of its own: no ground.
        Case(name: "the content is all strip", content: rect(0, 0, 800, 30), header: 38, grounds: []),
        Case(name: "the content is all vertical list", content: rect(0, 0, 40, 299), leading: 44, grounds: []),
        Case(name: "negative insets count as none", content: rect(0, 0, 399, 600), header: -5, footer: -5, leading: -5, grounds: [rect(399, 0, 401, 600)]),
    ]

    @Test(arguments: places)
    func theGroundFillsWhatTheHeldContentLeavesOpen(_ place: Case) {
        let grounds = PaneClipView.heldGroundRects(clip: Self.clip, content: place.content, header: place.header, footer: place.footer, leading: place.leading)
        #expect(grounds == place.grounds, "\(place.name): the ground is \(grounds), not \(place.grounds)")
    }

    /// One pixel of a 2x screen, at each edge: the last frames of a split's spring.
    nonisolated static let onePixelAtTwoX: [Case] = [
        Case(name: "0.5 pt below", content: rect(0, 0, 800, 599.5), header: 38, grounds: [rect(0, 599.5, 800, 0.5)]),
        Case(name: "0.5 pt above", content: rect(0, 0.5, 800, 599.5), header: 38, grounds: [rect(0, 0, 800, 0.5)]),
        Case(name: "0.5 pt right", content: rect(0, 0, 799.5, 600), grounds: [rect(799.5, 0, 0.5, 600)]),
        Case(name: "0.5 pt left", content: rect(0.5, 0, 799.5, 600), grounds: [rect(0, 0, 0.5, 600)]),
        Case(name: "0.5 pt below and right", content: rect(0, 0, 799.5, 599.5), grounds: [rect(0, 599.5, 799.5, 0.5), rect(799.5, 0, 0.5, 600)]),
    ]

    @Test(arguments: onePixelAtTwoX)
    func aPartOnePixelThickOnATwoXScreenIsGroundToo(_ place: Case) {
        let grounds = PaneClipView.heldGroundRects(clip: Self.clip, content: place.content, header: place.header, footer: place.footer, leading: place.leading)
        #expect(grounds == place.grounds, "\(place.name): the pane shows a line of the window's color one pixel thick: the ground is \(grounds), not \(place.grounds)")
    }
}

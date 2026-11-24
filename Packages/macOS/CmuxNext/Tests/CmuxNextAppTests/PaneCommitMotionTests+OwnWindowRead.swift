import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
@testable import CmuxNextLayout
import Testing

/// A view of a riding kind that can draw in a window of its own.
@MainActor private final class RidingOwnWindowView: NSView, PaneCommitMotionRiding, PaneContentOwnWindow {
    var drawsInOwnWindow = false
}

/// A view of no riding kind that draws in a window of its own, or in its own layer.
@MainActor private final class OwnWindowPart: NSView, PaneContentOwnWindow {
    var drawsInOwnWindow = true
}

/// `PaneCommitMotionTests`, the two reads of content that draws in a window of its own.
///
/// The pane that moves is read by the riding rule (`NSView.paneRidesCommitMotion`). A pane beside a zoom's or an
/// unzoom's move is read by the layout (`NSView.paneShowsOwnWindow`). The two walk the same views: the view, and its
/// shown direct subviews.
extension PaneCommitMotionTests {
    /// For a view of a riding kind the two reads are opposite in each case: the view itself draws so; a shown direct
    /// subview does; a hidden subview does (no window of its own shows); a subview draws in its own layer; and the
    /// top view of a content area has a shown direct subview that draws so.
    @Test func theLayoutAndTheRidingRuleReadAWindowOfItsOwnAlike() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let itself = RidingOwnWindowView(frame: frame)
        itself.drawsInOwnWindow = true
        let shown = RidingOwnWindowView(frame: frame)
        shown.addSubview(OwnWindowPart(frame: frame))
        let hidden = RidingOwnWindowView(frame: frame)
        let parked = OwnWindowPart(frame: frame)
        parked.isHidden = true
        hidden.addSubview(parked)
        let inLayer = RidingOwnWindowView(frame: frame)
        let part = OwnWindowPart(frame: frame)
        part.drawsInOwnWindow = false
        inLayer.addSubview(part)
        let (content, area) = Self.content()
        let top = RidingOwnWindowView(frame: area.bounds)
        top.addSubview(OwnWindowPart(frame: top.bounds))
        area.addSubview(top)
        let cases: [(name: String, view: NSView, wanted: Bool)] = [
            ("the view itself", itself, true), ("a shown direct subview", shown, true), ("a hidden subview", hidden, false),
            ("a subview that draws in its own layer", inLayer, false), ("the top view of a content area", content, true),
        ]
        for each in cases {
            let shows = each.view.paneShowsOwnWindow, rides = each.view.paneRidesCommitMotion
            #expect(shows == each.wanted, "\(each.name): the layout reads a window of its own: \(shows)")
            #expect(rides == !each.wanted, "\(each.name): the riding rule says that the view rides: \(rides)")
        }
    }
}

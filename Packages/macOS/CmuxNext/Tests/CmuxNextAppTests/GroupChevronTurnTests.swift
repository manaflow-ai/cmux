import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import QuartzCore
import Testing

/// Lawrence msg 15763: "should animate rotation of the chevron when i open/close group". A user's fold turns the
/// header's one chevron glyph on the sidebar's motion (right when collapsed, down when open), as the rows slide;
/// under Reduce Motion it turns at once, with no animation.
@MainActor @Suite(.serialized) struct GroupChevronTurnTests {
    static let rotation = "transform.rotation.z"

    /// The chevron's layers: its view's layer and every sublayer.
    static func layers(_ header: GroupHeaderRowView) throws -> [CALayer] {
        let view = try #require(GroupHeaderTrailingTests.chevronView(header), "no chevron view at the chevron's frame")
        let root = try #require(view.layer, "the chevron has no layer")
        func walk(_ layer: CALayer) -> [CALayer] { [layer] + (layer.sublayers ?? []).flatMap(walk) }
        return walk(root)
    }

    /// The chevron's rotation animation, nil when it turned at once.
    static func turn(_ header: GroupHeaderRowView) throws -> CAAnimation? {
        try layers(header).lazy.compactMap { $0.animation(forKey: rotation) }.first
    }

    /// The angle the chevron's glyph rests at (the model value, not the animation's frame), in radians.
    static func angle(_ header: GroupHeaderRowView) throws -> CGFloat {
        let turned = try layers(header).map { (($0.value(forKeyPath: rotation) as? NSNumber)?.doubleValue ?? 0) }
        return CGFloat(turned.first { abs($0) > 0.001 } ?? 0)
    }

    @Test func openingAndClosingAGroupTurnsTheChevron() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let (header, sidebar) = try GroupHeaderTrailingTests.header(activity: .idle, unread: .none)
        let group = GroupHeaderTrailingTests.group
        let resting = try Self.angle(header)
        #expect(resting == 0, "a collapsed group's chevron is turned \(resting), not pointing right")
        #expect(try Self.turn(header) == nil, "the chevron turns with nothing folded")

        sidebar.list.model.noteUserIntent() // a click on the header
        sidebar.list.model.setGroupCollapsed(group, false)
        let open = try #require(sidebar.list.rowViews[.group(group)] as? GroupHeaderRowView)
        #expect(open.debugDisclosure?.icon == "disclosure.expanded", "the open header reads \(String(describing: open.debugDisclosure))")
        let opening = try #require(try Self.turn(open), "opening the group snapped the chevron down with no rotation")
        #expect(opening.duration > 0, "the opening turn takes no time")
        let opened = try Self.angle(open)
        #expect(abs(abs(opened) - .pi / 2) < 0.001, "the open chevron rests at \(opened) rad, not a quarter turn")

        sidebar.list.model.noteUserIntent()
        sidebar.list.model.setGroupCollapsed(group, true)
        let closed = try #require(sidebar.list.rowViews[.group(group)] as? GroupHeaderRowView)
        #expect(closed.debugDisclosure?.icon == "disclosure.collapsed")
        #expect(try Self.turn(closed) != nil, "closing the group snapped the chevron right with no rotation")
        let shut = try Self.angle(closed)
        #expect(shut == 0, "the closed chevron rests at \(shut) rad, not pointing right")
    }

    /// Reduce Motion: the chevron takes its new direction at once.
    @Test func underReduceMotionTheChevronTurnsAtOnce() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let (_, sidebar) = try GroupHeaderTrailingTests.header(activity: .idle, unread: .none)
        let group = GroupHeaderTrailingTests.group
        sidebar.list.model.noteUserIntent()
        sidebar.list.model.setGroupCollapsed(group, false)
        let open = try #require(sidebar.list.rowViews[.group(group)] as? GroupHeaderRowView)
        #expect(try Self.turn(open) == nil, "the chevron animates its turn under Reduce Motion")
        let opened = try Self.angle(open)
        #expect(abs(abs(opened) - .pi / 2) < 0.001, "the open chevron rests at \(opened) rad, not a quarter turn")
    }

    /// A recycled header for another, open group shows its chevron down at once: no turn left over from the last group.
    @Test func aReconfiguredHeaderDoesNotTurnOnItsFirstShow() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let (header, _) = try GroupHeaderTrailingTests.header(activity: .idle, unread: .none)
        header.prepareForReuse(key: header.key)
        #expect(try Self.turn(header) == nil, "a recycled header keeps a turn animation")
    }
}

import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-11-17, on the "Chief's workspaces" rail zoomed in: "group left bar is not pixel perfect, it needs proper
/// even roundness, and have slight padding on left as well, and identical color/texture to the workspace group". Every
/// open group's rail (the colored one and the no-color one) is a capsule: both ends rounded by half its width, no tip;
/// it sits centred in its lane, the same room from the header bar's left edge as from its members' fills, on the
/// 2x pixel grid; and a no-color group's rail is painted exactly as its header bar's pane is, light and dark.
@MainActor @Suite(.serialized, .closesItsWindows) struct GroupRailPolishTests {
    static let allCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]

    /// The layer that clips a group's rail and the shape layer that paints it, and the rail's frame in list coordinates.
    static func rail(_ sidebar: SidebarView, _ id: GroupID) throws -> (clip: CALayer, paint: CAShapeLayer, frame: CGRect) {
        let frame = try #require(sidebar.list.groupLineViews.shown[id]?.frame, "\(id) has no line view")
        let view = try #require(GroupPaletteDefaultTests.views(GroupLineView.self, in: sidebar).first { $0.frame == frame })
        view.updateLayer()
        view.layout()
        if view.isBlock {
            #expect(!view.blockRail.isHidden, "\(id): the block draws no rail")
            return (view.blockRail, view.blockRailShape, view.blockRail.frame.offsetBy(dx: frame.minX, dy: frame.minY))
        }
        return (try #require(view.layer), view.railShape, frame)
    }

    static func srgb(_ color: CGColor?) throws -> NSColor {
        try #require(color.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB))
    }

    @Test(arguments: [false, true])
    func everyRailIsAnEvenCapsuleCentredInItsLane(dark: Bool) throws {
        try NoColorGroupBlockTests.withLook(.glass) {
            let (sidebar, window) = ChiefGroupRailTests.sidebar()
            defer { window.close() }
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            sidebar.layoutSubtreeIfNeeded()
            let list = sidebar.list
            for (id, member) in [(ChiefGroupRailTests.chief, ChiefGroupRailTests.chiefMembers[0]),
                                 (ChiefGroupRailTests.agents, ChiefGroupRailTests.agentMembers[0])] {
                let (clip, paint, frame) = try Self.rail(sidebar, id)
                // Even roundness: every corner of the clip rounds by half the width, and the body is a plain bar.
                #expect(clip.maskedCorners == Self.allCorners, "\(id): only \(clip.maskedCorners.rawValue) of the corners round")
                #expect(clip.cornerRadius == frame.width / 2, "\(id): corner \(clip.cornerRadius), width \(frame.width)")
                let path = try #require(paint.path)
                #expect(path.contains(CGPoint(x: frame.width - 0.05, y: 0.05)), "\(id): the bar's top right is cut away (a tip, not a cap)")
                // A slight padding on the left: centred between the header bar's left edge and its members' fills.
                let header = try #require(list.rowViews[.group(id)]).frame
                let row = try #require(list.rowViews[.workspace(member)]).frame
                let left = frame.minX - header.minX, right = row.minX - frame.maxX
                #expect(left > 0, "\(id): the rail sits flush on the bar's left edge (\(left) pt)")
                #expect(abs(left - right) < 0.01, "\(id): \(left) pt left of the rail, \(right) pt right of it")
                // Pixel perfect at 2x: on the rows' own half-point grid.
                let grid = [frame.minX, frame.minY, frame.width, frame.maxY].allSatisfy { ($0 * 2).rounded() == $0 * 2 }
                #expect(grid, "\(id): the rail \(frame) is off the 2x pixel grid")
            }
        }
    }

    @Test(arguments: [false, true])
    func theNoColorRailIsItsHeadersPane(dark: Bool) throws {
        try NoColorGroupBlockTests.withLook(.glass) {
            for (name, scope) in try GroupPaletteDefaultTests.themes() where name == (dark ? "dark" : "light") {
                let (sidebar, window) = ChiefGroupRailTests.sidebar()
                defer { window.close() }
                scope.root(sidebar)
                sidebar.layoutSubtreeIfNeeded()
                let header = try #require(sidebar.list.rowViews[.group(ChiefGroupRailTests.chief)] as? GroupHeaderRowView)
                header.updateLayer()
                let pane = try Self.srgb(header.pill.backgroundColor)
                let rail = try Self.srgb(try Self.rail(sidebar, ChiefGroupRailTests.chief).paint.fillColor)
                let same = [(pane.redComponent, rail.redComponent), (pane.greenComponent, rail.greenComponent),
                            (pane.blueComponent, rail.blueComponent), (pane.alphaComponent, rail.alphaComponent)]
                    .allSatisfy { abs($0 - $1) < 0.01 }
                #expect(same, "\(name): the rail is \(rail), its header's pane \(pane)")
            }
        }
    }
}

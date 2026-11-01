import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-10-20 (u5506): "when reordering groups around, we have an
/// animation that makes it bigger, i dont like it, i think it should just
/// stay in place, also bg of group when dragged around needs to be modern
/// apple liquid glass (handle old macos versions well tho)".
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarDragLiftGlassTests {
    static let group = GroupID("g-lift-glass")

    static func list() -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let ws = { (id: String) in SidebarWorkspace(id: WorkspaceID(id), title: id) }
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [
                .workspace(ws("loose-a")),
                .group(SidebarGroup(id: group, name: "Group", color: .purple, workspaces: [ws("m1"), ws("m2"), ws("m3")])),
                .workspace(ws("loose-b")),
            ]),
        ], activeWorkspaceID: nil)
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        return (list, window)
    }

    /// A lifted group keeps its size: no scale on the card, now or animating.
    @Test(arguments: [false, true])
    func aLiftedCardDoesNotGrow(animated: Bool) throws {
        let lift = DragLiftView(content: NSView(), count: 1)
        lift.frame = NSRect(x: 0, y: 0, width: 220, height: 160)
        lift.layout()
        lift.setLifted(true, animated: animated)
        lift.layout()
        let layer = try #require(lift.layer)
        #expect(CATransform3DIsIdentity(layer.sublayerTransform), "the lifted card is scaled")
        #expect(layer.animation(forKey: "sublayerTransform") == nil, "the lift animates a scale")
    }

    /// Dragging a real group header: the card sits on the group's own frame and never scales.
    @Test func aDraggedGroupStaysItsSizeAndInPlace() throws {
        let (list, window) = Self.list()
        defer { window.close() }
        let header = try #require(list.displayed.row(for: .group(Self.group)))
        let start = NSPoint(x: 80, y: header.y + header.height / 2)
        list.press = SidebarPress(key: header.key, point: start)
        list.beginDrag(try #require(list.press))
        defer {
            list.cancelDrag()
            if let landing = list.landing { list.finishLand(landing, then: nil) }
        }
        let lift = try #require(list.subviews.first { $0 is DragLiftView } as? DragLiftView)
        let last = try #require(list.displayed.row(for: .workspace(WorkspaceID("m3"))))
        // The group's block: its rows and its members' line, which runs just left of them (#23975).
        let line = try #require(SidebarGroupLine.lines(list.displayed.rows, colors: list.groups) { list.frame(for: $0) }.first)
        let block = list.frame(for: header).union(list.frame(for: last)).union(line.frame)
        #expect(lift.frame.size == block.size, "the card is not the group's size")
        #expect(lift.frame.minX == block.minX, "the card moved sideways")
        #expect(CATransform3DIsIdentity(try #require(lift.layer).sublayerTransform))
    }

    /// The card's background is the one overlay glass: Liquid Glass on macOS
    /// 26+, the frosted material before, opaque under Reduce Transparency.
    @Test(arguments: [OverlayMaterial.liquidGlass, .vibrancy, .opaque])
    func theCardDrawsTheOverlayMaterial(material: OverlayMaterial) throws {
        let lift = DragLiftView(content: NSView(), count: 1, material: material)
        lift.frame = NSRect(x: 0, y: 0, width: 220, height: 28)
        lift.layout()
        #expect(lift.background.material == material)
        #expect(lift.background.isInteractive == false, "the card must let the pointer through")
        switch material {
        case .liquidGlass:
            let glass = Self.descendants(lift.background).compactMap { $0 as? GlassPanelView }.first
            #expect(glass != nil, "no glass panel")
            #expect(glass?.isLiquidGlass == Glass.isLiquidGlassAvailable, "glass not chosen per OS version")
        case .vibrancy:
            #expect(Self.descendants(lift.background).contains { $0 is NSVisualEffectView }, "no frosted material before macOS 26")
        case .opaque:
            #expect(!Self.descendants(lift.background).contains { $0 is NSVisualEffectView })
        }
    }

    /// With no material pinned the card follows this Mac (OS version and Reduce Transparency).
    @Test func theDefaultMaterialFollowsThisMac() {
        let lift = DragLiftView(content: NSView(), count: 1)
        #expect(lift.background.material == OverlayMaterial.select(
            liquidGlassAvailable: Glass.isLiquidGlassAvailable, reduceTransparency: ReduceTransparency.shared.isEnabled))
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants($0) }
    }
}

import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-20 (u5506): "when reordering groups around, we have an
/// animation that makes it bigger, i dont like it, i think it should just
/// stay in place, also bg of group when dragged around needs to be modern
/// apple liquid glass (handle old macos versions well tho)".
@MainActor @Suite(.serialized) struct SidebarDragLiftGlassTests {
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

    private func translucent(_ body: () throws -> Void) rethrows {
        let original = ThemeScope.app.store.input
        let reduced = ReduceTransparency.shared.override
        defer {
            _ = ThemeScope.app.store.apply(original)
            ReduceTransparency.shared.override = reduced
        }
        var input = original
        input.backgroundOpacity = 0.65
        _ = ThemeScope.app.store.apply(input)
        ReduceTransparency.shared.override = false
        try body()
    }

    /// No second material or opaque sheet can cover the window's patterned backdrop.
    /// This fails for both the old regular overlay and the unsuccessful clear-glass overlay.
    @Test(arguments: [OverlayMaterial.liquidGlass, .vibrancy])
    func translucentLiftReusesTheWindowBackdrop(material: OverlayMaterial) throws {
        try translucent {
            let lift = DragLiftView(content: NSView(), count: 1, material: material)
            lift.frame = NSRect(x: 0, y: 0, width: 220, height: 80)
            lift.layoutSubtreeIfNeeded()
            #expect(lift.isGlass)
            for view in [lift as NSView] + Self.descendants(lift) {
                #expect(!(view is NSVisualEffectView) && !(view is GlassPanelView), "a second material flattens the checker")
                #expect((view.layer?.backgroundColor?.alpha ?? 0) == 0, "an opaque sheet covers the checker")
            }
        }
    }

    /// The accessibility observer rebuilds the live card in both directions during a drag.
    @Test func transparencyReturnsAfterReduceTransparencyTurnsOff() throws {
        try translucent {
            let lift = DragLiftView(content: NSView(), count: 1)
            ReduceTransparency.shared.override = true
            #expect(!lift.isGlass)
            #expect(Self.descendants(lift.background).contains { $0.layer?.backgroundColor?.alpha == 1 })
            ReduceTransparency.shared.override = false
            #expect(lift.isGlass)
            #expect(Self.descendants(lift.background).allSatisfy { ($0.layer?.backgroundColor?.alpha ?? 0) == 0 })
        }
    }

    @Test func opaqueWindowKeepsItsCard() {
        let original = ThemeScope.app.store.input
        let selection = ThemeScope.app.backdropSelection
        defer {
            _ = ThemeScope.app.store.apply(original)
            ThemeScope.app.setBackdropSelection(selection)
        }
        var input = original
        input.backgroundOpacity = 1
        _ = ThemeScope.app.store.apply(input)
        ThemeScope.app.setBackdropSelection(nil)
        let lift = DragLiftView(content: NSView(), count: 1)
        #expect(!lift.isGlass)
        #expect(Self.descendants(lift.background).contains { $0.layer?.backgroundColor?.alpha == 1 })
    }

    /// Real workspace and group drag content uses the same alpha fills as the resting rows.
    @Test(arguments: [false, true])
    func liftedRowsNeverIncreaseTheirStateFillOpacity(group: Bool) throws {
        try translucent {
            let (list, window) = Self.list()
            defer { window.close() }
            let key: SidebarRowKey = group ? .group(Self.group) : .workspace(WorkspaceID("loose-a"))
            let header = try #require(list.displayed.row(for: key))
            list.press = SidebarPress(key: key, point: NSPoint(x: 80, y: header.y + header.height / 2))
            list.beginDrag(try #require(list.press))
            defer {
                list.cancelDrag()
                if let landing = list.landing { list.finishLand(landing, then: nil) }
            }
            let lift = try #require(list.subviews.first { $0 is DragLiftView } as? DragLiftView)
            #expect(!Self.descendants(lift).contains { $0 is NSVisualEffectView || $0 is GlassPanelView })
            let rows = Self.descendants(lift).compactMap { $0 as? SidebarRowView }
            #expect(!rows.isEmpty)
            for row in rows {
                #expect(row.isLifted)
                row.isSelected = true
                row.updateLayer()
                let restingAlpha = row.performWithTheme { Palette.selectionFill.alphaComponent }
                if let header = row as? GroupHeaderRowView {
                    let bound = WindowBackdrop.dragPreview(header.themeScope, reduceTransparency: false).dragLiftAlpha
                    #expect((header.pill.backgroundColor?.alpha ?? 0) <= bound)
                }
                if let workspace = row as? WorkspaceRowView {
                    #expect((workspace.layer?.backgroundColor?.alpha ?? 0) <= restingAlpha)
                    #expect(workspace.rowBadge.ringColor.alpha <= restingAlpha)
                }
            }
            let child = SidebarTabRowView(key: .tab(WorkspaceID("m1"), TabID("terminal")))
            child.isHovered = true
            child.updateLayer()
            let restingChild = try #require(child.layer?.backgroundColor)
            child.isLifted = true
            child.updateLayer()
            #expect(child.layer?.backgroundColor == restingChild,
                    "a faint child-row highlight must not become a dense drag fill")
        }
    }

    /// The badge cutout must use the same state fill as the lifted row, including when selected.
    @Test func liftedWorkspaceBadgeUsesTheLiftedStateFill() throws {
        try translucent {
            let row = WorkspaceRowView(key: .workspace(WorkspaceID("badge-lift")))
            row.isSelected = true
            row.updateLayer()
            let restingRing = row.rowBadge.ringColor
            row.isLifted = true
            row.updateLayer()
            let expected = row.performWithTheme { row.liftedFill(Palette.selectionFill).cgColor }
            #expect(row.rowBadge.ringColor == expected, "badge ring still uses an opaque resting backdrop")
            #expect(row.rowBadge.ringColor.alpha < 1)
            row.isLifted = false
            row.updateLayer()
            #expect(row.rowBadge.ringColor == restingRing)
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

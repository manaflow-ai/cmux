import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// SIDEBAR-SELECTION-NO-TRAVEL-ANIMATION: the selection highlight changes in
/// place, at once, in every section. After a selection change exactly one
/// layer draws the selection fill, it already sits on the new item, and it
/// runs no position, size, fade or color animation (no travel from the old
/// item, no intermediate frames). One selection model
/// (SIDEBAR-SELECTION-ONE-MODEL) still decides which item that is.
@MainActor @Suite struct SidebarSelectionHighlightTests {
    static func sidebar() -> (SidebarModel, SidebarView) {
        let nodes = ["a", "b"].map { SidebarNode.workspace(SidebarWorkspace(id: WorkspaceID($0), machineID: .local, title: $0, rowState: .live)) }
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "Local", kind: .local)), nodes: nodes)])
        // The bridge gives every layout item its info; the selected top item's info is marked active.
        for section in model.layout.sections {
            for item in section.items { model.itemInfo[item.id] = SidebarItemInfo.fallback(for: item.ref) }
        }
        let sidebar = SidebarView(model: model)
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        sidebar.layoutSubtreeIfNeeded()
        return (model, sidebar)
    }

    /// One layer that draws the selection fill now, and its frame in the sidebar.
    struct Drawn {
        var layer: CALayer
        var frame: CGRect
        /// Keys of running animations that would move, resize, fade or recolor it.
        var travel: [String] {
            (layer.animationKeys() ?? []).filter { ["position", "bounds", "opacity", "backgroundColor", "frameOrigin", "frameSize"].contains($0) }
        }
    }

    /// Every visible layer in `sidebar` that draws the selection fill. Views
    /// paint their layers first (no window runs a display pass in a test).
    static func highlights(in sidebar: SidebarView) -> [Drawn] {
        sidebar.layoutSubtreeIfNeeded()
        let fill = sidebar.performWithTheme { Palette.selectionFill.cgColor }
        var seen = Set<ObjectIdentifier>()
        var out: [Drawn] = []
        func visit(_ view: NSView) {
            if view.wantsUpdateLayer, view.layer != nil { view.updateLayer() }
            if let root = view.layer, !view.isHiddenOrHasHiddenAncestor, view.alphaValue > 0 {
                let subviewLayers = Set(view.subviews.compactMap { $0.layer.map(ObjectIdentifier.init) })
                func walk(_ layer: CALayer, frame: CGRect) {
                    guard seen.insert(ObjectIdentifier(layer)).inserted, !layer.isHidden, layer.opacity > 0 else { return }
                    if layer.backgroundColor == fill, !frame.isEmpty { out.append(Drawn(layer: layer, frame: frame)) }
                    for sub in layer.sublayers ?? [] where !subviewLayers.contains(ObjectIdentifier(sub)) {
                        walk(sub, frame: view.convert(sub.convert(sub.bounds, to: root), to: sidebar))
                    }
                }
                walk(root, frame: view.convert(view.bounds, to: sidebar))
            }
            view.subviews.forEach(visit)
        }
        visit(sidebar)
        return out
    }

    static func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5 && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    static func rowFrame(_ id: String, in sidebar: SidebarView) throws -> CGRect {
        let row = try #require(sidebar.list.displayed.row(for: .workspace(WorkspaceID(id))))
        return sidebar.list.convert(sidebar.list.frame(for: row), to: sidebar)
    }

    /// Selects `item`, lets the sidebar render, and checks that one highlight
    /// sits inside `target` at once with no animation.
    static func expectInPlace(_ sidebar: SidebarView, _ model: SidebarModel, select item: SidebarItem, target: () throws -> CGRect,
                              exact: Bool, _ comment: Comment) async throws {
        model.selectedItem = item
        // The list and the top regions render in the same main-thread turn
        // (one CA commit); wait for both, then check that nothing animates.
        await settle {
            let drawn = highlights(in: sidebar)
            return drawn.count == 1 && ((try? target()).map { t in exact ? near(drawn[0].frame, t) : t.contains(drawn[0].frame) } ?? false)
        }
        let drawn = highlights(in: sidebar)
        let t = try target()
        #expect(drawn.count == 1, "exactly one highlight: \(comment)")
        let one = try #require(drawn.first)
        #expect(exact ? near(one.frame, t) : t.insetBy(dx: -0.5, dy: -0.5).contains(one.frame), "on the new item at once: \(comment)")
        #expect(one.travel.isEmpty, "no travel animation (\(one.travel)): \(comment)")
    }

    @Test func theHighlightChangesInPlaceAcrossSectionsAndRows() async throws {
        let (model, sidebar) = Self.sidebar()
        let storeID = LayoutItemID("itm_app_store")
        func store() throws -> CGRect {
            let view = try #require(sidebar.aboveRegion.itemView(storeID))
            return view.convert(view.bounds, to: sidebar)
        }
        try await Self.expectInPlace(sidebar, model, select: .topItem(storeID), target: store, exact: false, "App Store")
        try await Self.expectInPlace(sidebar, model, select: .workspace(WorkspaceID("a")), target: { try Self.rowFrame("a", in: sidebar) },
                                     exact: true, "App Store to workspace a")
        try await Self.expectInPlace(sidebar, model, select: .workspace(WorkspaceID("b")), target: { try Self.rowFrame("b", in: sidebar) },
                                     exact: true, "workspace a to workspace b")
        try await Self.expectInPlace(sidebar, model, select: .topItem(storeID), target: store, exact: false, "workspace b to App Store")
    }

    /// debug.sidebar_rows reports the same single highlight: items "active"
    /// plus rows "selected" name exactly the selected item.
    @Test func theDebugReportNamesExactlyOneHighlight() async {
        let (model, sidebar) = Self.sidebar()
        let storeID = LayoutItemID("itm_app_store")
        func marked() -> [String] {
            sidebar.debugLayoutItems().filter(\.isActive).map(\.id) + sidebar.debugRows().rows.filter(\.selected).map(\.key)
        }
        for item in [SidebarItem.topItem(storeID), .workspace(WorkspaceID("a")), .workspace(WorkspaceID("b")), .topItem(storeID)] {
            let expected: [String]
            switch item {
            case let .workspace(id): expected = [String(describing: SidebarRowKey.workspace(id))]
            case let .topItem(id): expected = [id.rawValue]
            case .group: expected = []
            }
            model.selectedItem = item
            await Self.settle { marked() == expected && Self.highlights(in: sidebar).count == 1 }
            #expect(marked() == expected, "exactly one highlight for \(item)")
        }
    }

    @Test func noSelectionDrawsNoHighlight() async {
        let (model, sidebar) = Self.sidebar()
        model.selectedItem = .workspace(WorkspaceID("a"))
        await Self.settle { !Self.highlights(in: sidebar).isEmpty }
        model.selectedItem = nil
        await Self.settle { Self.highlights(in: sidebar).isEmpty }
        #expect(Self.highlights(in: sidebar).isEmpty)
    }
}

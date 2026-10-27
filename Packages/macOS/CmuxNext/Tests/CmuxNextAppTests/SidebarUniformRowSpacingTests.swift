import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-21, on the cmux NEXT sidebar: "ALL THIS RELATIVELY UNNECESSARY SPACING AFTER GROUPS AND
/// AFTER PINS". Rows keep one gap, the list's row spacing, between every two of them: under a group's
/// last member, under a folder's last row, under the Pinned block's last row and under the last pinned
/// chat, as between any two rows. A pinned workspace row's pin starts where an unpinned row's content
/// starts and centers on its row as that row's content does.
@MainActor @Suite(.serialized)
struct SidebarUniformRowSpacingTests {
    static let group = GroupID("grp")
    static let pins = [LayoutItemID("itm_pin_1"), LayoutItemID("itm_pin_2")]
    static let pinnedKey = SidebarRowKey.block(SidebarLayoutDocument.pinnedSectionID.rawValue)

    static func ws(_ id: String) -> SidebarWorkspace { SidebarWorkspace(id: WorkspaceID(id), title: id) }

    /// A machine section: group `grp` (w1, w2), then loose w3 and w4.
    static func machine() -> CmuxNextSidebar.SidebarSection {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        return CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: [
            .group(SidebarGroup(id: group, name: "Group", workspaces: [ws("w1"), ws("w2")])),
            .workspace(ws("w3")), .workspace(ws("w4")),
        ])
    }

    static func pinnedBlock() -> CmuxNextSidebar.SidebarSection {
        CmuxNextSidebar.SidebarSection(kind: .custom(SidebarCustomSection(id: SidebarLayoutDocument.pinnedSectionID.rawValue)), nodes: [])
    }

    static func row(_ layout: SidebarLayout, _ id: String) throws -> SidebarRow {
        try #require(layout.row(for: .workspace(WorkspaceID(id))), "no row for \(id)")
    }

    // MARK: The layout (pure)

    @Test(arguments: SidebarDensity.allCases) func aGroupsLastRowAndTheNextRowKeepTheRowSpacing(_ density: SidebarDensity) throws {
        let saved = DesignSettings.shared.sidebarSections.density
        DesignSettings.shared.sidebarSections.density = density
        defer { DesignSettings.shared.sidebarSections.density = saved }
        let m = SidebarLayoutMetrics.standard
        let layout = SidebarLayout.make(sections: [Self.machine()], metrics: m)
        let header = try #require(layout.row(for: .group(Self.group)))
        let (w1, w2, w3, w4) = try (Self.row(layout, "w1"), Self.row(layout, "w2"), Self.row(layout, "w3"), Self.row(layout, "w4"))
        #expect(abs(w1.y - header.maxY - m.rowSpacing) < 0.01)
        #expect(abs(w2.y - w1.maxY - m.rowSpacing) < 0.01)
        #expect(abs(w3.y - w2.maxY - m.rowSpacing) < 0.01, "the group's end adds \(w3.y - w2.maxY - m.rowSpacing) pt to the row spacing")
        #expect(abs(w4.y - w3.maxY - m.rowSpacing) < 0.01)
    }

    @Test func aFoldedGroupAndAnOpenedOneEndTheSameWay() throws {
        let m = SidebarLayoutMetrics.standard
        var collapsed = Self.machine()
        if case var .group(group) = collapsed.nodes[0] {
            group.isCollapsed = true
            collapsed.nodes[0] = .group(group)
        }
        let layout = SidebarLayout.make(sections: [collapsed], metrics: m)
        let header = try #require(layout.row(for: .group(Self.group)))
        let w3 = try Self.row(layout, "w3")
        #expect(abs(w3.y - header.maxY - m.rowSpacing) < 0.01)
        // The fold's splice lays the open group out as `make` does.
        let opened = SidebarLayout.make(sections: [Self.machine()], metrics: m)
        guard case let .group(group) = Self.machine().nodes[0] else { return }
        let spliced = try #require(layout.folding(group, collapsed: false, in: Self.machine(), metrics: m, options: SidebarLayoutOptions()))
        #expect(spliced.rows == opened.rows)
        #expect(spliced.totalHeight == opened.totalHeight)
    }

    @Test func aFoldersLastRowAndTheNextFolderKeepTheRowSpacing() throws {
        let m = SidebarLayoutMetrics.standard
        var a = Self.ws("a"), b = Self.ws("b")
        (a.folder, b.folder) = ("~/one", "~/two")
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        var options = SidebarLayoutOptions()
        options.grouping.by = .folder
        let layout = SidebarLayout.make(sections: [CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: [.workspace(a), .workspace(b)])],
                                        metrics: m, options: options)
        let rowA = try Self.row(layout, "a")
        let second = try #require(layout.row(for: .folder(.machine(.local), "~/two")))
        #expect(abs(second.y - rowA.maxY - m.rowSpacing) < 0.01, "a folder's end adds \(second.y - rowA.maxY - m.rowSpacing) pt")
    }

    @Test func theRowUnderThePinnedBlockKeepsTheRowSpacing() throws {
        let m = SidebarLayoutMetrics.standard
        var options = SidebarLayoutOptions()
        options.blockHeights = [SidebarLayoutDocument.pinnedSectionID.rawValue: 52]
        let layout = SidebarLayout.make(sections: [Self.pinnedBlock(), Self.machine()], metrics: m, options: options)
        let block = try #require(layout.row(for: Self.pinnedKey))
        let header = try #require(layout.row(for: .group(Self.group)))
        #expect(abs(header.y - block.maxY - m.rowSpacing) < 0.01, "the pins' end adds \(header.y - block.maxY - m.rowSpacing) pt")
    }

    /// A drop's gap alone under the Pinned block moves the rows below by exactly the gap's shift, as the drag's hit
    /// test assumes (`SidebarDragGeometry.baseY`).
    @Test func aGapUnderThePinnedBlockMovesTheRowsBelowByItsShift() throws {
        let m = SidebarLayoutMetrics.standard
        var options = SidebarLayoutOptions()
        options.blockHeights = [SidebarLayoutDocument.pinnedSectionID.rawValue: 52]
        let base = SidebarLayout.make(sections: [Self.pinnedBlock(), Self.machine()], metrics: m, options: options)
        options.gap = DropPosition(section: .custom(SidebarLayoutDocument.pinnedSectionID.rawValue), group: nil, index: 0)
        options.gapHeight = m.rowHeight
        let open = SidebarLayout.make(sections: [Self.pinnedBlock(), Self.machine()], metrics: m, options: options)
        let gapY = try #require(open.gapY)
        let block = try #require(open.row(for: Self.pinnedKey))
        #expect(gapY >= block.maxY)
        let before = try #require(base.row(for: .group(Self.group)))
        let after = try #require(open.row(for: .group(Self.group)))
        #expect(abs(after.y - before.y - open.gapShift) < 0.01, "the rows below moved \(after.y - before.y) pt, the gap's shift is \(open.gapShift) pt")
    }

    /// A drag that empties the Pinned block shows its drop zone under the block (or alone, for a section without a
    /// title, whose block is then 0 pt tall); the next row follows the zone (or the drop's gap in its place) by the
    /// row spacing, not a section gap on top of it.
    @Test(arguments: [false, true], [CGFloat(0), 24]) func theRowUnderThePinnedDropZoneKeepsTheRowSpacing(_ gapInZone: Bool, _ blockHeight: CGFloat) throws {
        let m = SidebarLayoutMetrics.standard
        let pinnedID = SidebarLayoutDocument.pinnedSectionID.rawValue
        var options = SidebarLayoutOptions()
        options.blockHeights = [pinnedID: blockHeight]
        options.showEmptyPinned = true
        options.emptyDocSections = [pinnedID]
        if gapInZone {
            options.gap = DropPosition(section: .custom(pinnedID), group: nil, index: 0)
            options.gapHeight = m.rowHeight
        }
        let layout = SidebarLayout.make(sections: [Self.pinnedBlock(), Self.machine()], metrics: m, options: options)
        let zoneEnd: CGFloat
        if gapInZone {
            zoneEnd = try #require(layout.gapY) + m.rowHeight
        } else {
            zoneEnd = try #require(layout.row(for: .emptySection(.custom(pinnedID)))).maxY
        }
        if blockHeight > 0 {
            let block = try #require(layout.row(for: Self.pinnedKey))
            #expect(zoneEnd - m.rowSpacing >= block.maxY)
        }
        let header = try #require(layout.row(for: .group(Self.group)))
        #expect(abs(header.y - zoneEnd - m.rowSpacing) < 0.01, "the drop zone's end adds \(header.y - zoneEnd - m.rowSpacing) pt")
    }

    /// Group by Status lists the rows under the Pinned block (or its drop zone) by the row spacing too.
    @Test(arguments: [false, true]) func theFirstStatusHeaderUnderThePinsKeepsTheRowSpacing(_ dropZone: Bool) throws {
        let m = SidebarLayoutMetrics.standard
        let pinnedID = SidebarLayoutDocument.pinnedSectionID.rawValue
        var options = SidebarLayoutOptions()
        options.grouping.setByStatus(true)
        options.blockHeights = [pinnedID: 24]
        if dropZone { (options.showEmptyPinned, options.emptyDocSections) = (true, [pinnedID]) }
        let layout = SidebarLayout.make(sections: [Self.pinnedBlock(), Self.machine()], metrics: m, options: options)
        let above = try #require(dropZone ? layout.row(for: .emptySection(.custom(pinnedID))) : layout.row(for: Self.pinnedKey))
        let header = try #require(layout.rows.first { if case .status = $0.key { true } else { false } }, "no status header")
        #expect(abs(header.y - above.maxY - m.rowSpacing) < 0.01, "the pins' end adds \(header.y - above.maxY - m.rowSpacing) pt")
    }

    /// Group by Status with a computer that lists nothing: the sidebar lays out as without that computer, so no
    /// spacing hangs under the Pinned block and a block after it still starts the list.
    @Test(arguments: [false, true]) func aStatusListWithNoRowsTakesNoSpace(_ blockFirst: Bool) throws {
        let m = SidebarLayoutMetrics.standard
        let docs = CmuxNextSidebar.SidebarSection(kind: .custom(SidebarCustomSection(id: "itm_docs")), nodes: [])
        let block = blockFirst ? Self.pinnedBlock() : docs
        let machine = CmuxNextSidebar.SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [])
        var options = SidebarLayoutOptions()
        options.grouping.setByStatus(true)
        options.blockHeights = [SidebarLayoutDocument.pinnedSectionID.rawValue: 24, "itm_docs": 24]
        let with = SidebarLayout.make(sections: blockFirst ? [block, machine] : [machine, block], metrics: m, options: options)
        let without = SidebarLayout.make(sections: [block], metrics: m, options: options)
        #expect(with.rows == without.rows, "\(with.rows.map(\.y)) vs \(without.rows.map(\.y))")
        #expect(abs(with.totalHeight - without.totalHeight) < 0.01, "the empty status list adds \(with.totalHeight - without.totalHeight) pt")
    }

    /// The same empty status list with Earlier chat history under the computers: a block after them starts below
    /// the history, not over it (a block that starts the list takes back its top padding).
    @Test func aBlockAfterTheEarlierHistoryStartsBelowIt() throws {
        let m = SidebarLayoutMetrics.standard
        let docs = CmuxNextSidebar.SidebarSection(kind: .custom(SidebarCustomSection(id: "itm_docs")), nodes: [])
        let machine = CmuxNextSidebar.SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [])
        var options = SidebarLayoutOptions()
        options.grouping.setByStatus(true)
        options.blockHeights = ["itm_docs": 24]
        options.sessionTree = SidebarSessionTreeState()
        let history = SidebarChatHistoryState(earlier: [SidebarHistoryChat(id: "e", title: "e", updatedAt: Date(timeIntervalSince1970: 0))],
                                              hasEarlier: true)
        options.chatHistory = history
        let layout = SidebarLayout.make(sections: [machine, docs], metrics: m, options: options)
        let earlierY = try #require(layout.earlierChatsY)
        let block = try #require(layout.row(for: .block("itm_docs")))
        #expect(block.y >= earlierY + history.earlierHeight(m), "the block starts at \(block.y), the history ends at \(earlierY + history.earlierHeight(m))")
    }

    @Test func theFirstWorkspaceRowFollowsTheLastPinnedChat() throws {
        let m = SidebarLayoutMetrics.standard
        var options = SidebarLayoutOptions()
        options.sessionTree = SidebarSessionTreeState()
        let history = SidebarChatHistoryState(pinned: [SidebarHistoryChat(id: "c", title: "c", updatedAt: Date(timeIntervalSince1970: 0))])
        options.chatHistory = history
        let layout = SidebarLayout.make(sections: [Self.machine()], metrics: m, options: options)
        let pinnedY = try #require(layout.pinnedChatsY)
        let header = try #require(layout.row(for: .group(Self.group)))
        // The pinned block's rows end with the row spacing (`pinnedHeight`), as list rows do.
        #expect(abs(header.y - (pinnedY + history.pinnedHeight(m))) < 0.01)
    }

    // MARK: The drawn list

    final class Harness {
        let model: SidebarModel
        let sidebar: SidebarView
        let window: NSWindow
        var list: SidebarListView { sidebar.list }

        init() {
            let pinned = LayoutSection(id: SidebarLayoutDocument.pinnedSectionID, showsTitle: false, region: .top, look: .builtIn,
                                       items: SidebarUniformRowSpacingTests.pins.enumerated().map { index, id in
                                           LayoutItem(id: id, ref: .workspace("pinned-\(index)"))
                                       })
            model = SidebarModel(sections: [SidebarUniformRowSpacingTests.pinnedBlock(), SidebarUniformRowSpacingTests.machine()],
                                 activeWorkspaceID: nil)
            model.layout = SidebarLayoutDocument(sections: [pinned])
            model.docDrag = SidebarDocDrag(item: { _ in nil }, section: { _ in nil }, begin: { _ in [:] }, drop: { _, _ in },
                                           adoptRef: { _ in nil })
            sidebar = SidebarView(model: model, design: DesignSettings.shared)
            sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 420)
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 420), styleMask: [.titled],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(sidebar)
            sidebar.layoutSubtreeIfNeeded()
            list.reload(animated: false)
            sidebar.layoutSubtreeIfNeeded()
            list.fitToClip()
            sidebar.layoutSubtreeIfNeeded()
            list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        }

        func pinnedRow(_ id: LayoutItemID) throws -> SidebarItemRowView {
            let block = try #require(list.rowViews[SidebarUniformRowSpacingTests.pinnedKey] as? SidebarBlockRowView, "the list draws no Pinned block")
            let row = try #require(block.region.itemViews[id], "no pinned row \(id)")
            row.layoutSubtreeIfNeeded()
            return row
        }

        func workspaceRow(_ id: String) throws -> WorkspaceRowView {
            let row = try #require(list.rowViews[.workspace(WorkspaceID(id))] as? WorkspaceRowView, "no row for \(id)")
            row.layoutSubtreeIfNeeded()
            return row
        }

        func inList(_ view: NSView) -> CGRect { list.convert(view.bounds, from: view) }
    }

    @Test(arguments: SidebarDensity.allCases) func everyDrawnRowKeepsTheOneGap(_ density: SidebarDensity) throws {
        let (saved, savedMotion) = (DesignSettings.shared.sidebarSections.density, Motion.reduceMotionOverride)
        (DesignSettings.shared.sidebarSections.density, Motion.reduceMotionOverride) = (density, true)
        defer { (DesignSettings.shared.sidebarSections.density, Motion.reduceMotionOverride) = (saved, savedMotion) }
        let h = Harness()
        defer { h.window.orderOut(nil) }
        let spacing = h.list.displayed.rowSpacing
        #expect(spacing > 0)
        let lastPin = h.inList(try h.pinnedRow(Self.pins[1]))
        let header = try #require(h.list.displayed.row(for: .group(Self.group)), "no group header")
        #expect(abs(header.y - lastPin.maxY - spacing) < 0.5,
                "under the pins: \(header.y - lastPin.maxY) pt, the row spacing is \(spacing) pt")
        let (w2, w3, w4) = try (h.inList(h.workspaceRow("w2")), h.inList(h.workspaceRow("w3")), h.inList(h.workspaceRow("w4")))
        #expect(abs(w3.minY - w2.maxY - spacing) < 0.5, "under the group: \(w3.minY - w2.maxY) pt, the row spacing is \(spacing) pt")
        #expect(abs(w4.minY - w3.maxY - spacing) < 0.5)
    }

    @Test(arguments: SidebarDensity.allCases) func thePinStartsAndCentersAsAnUnpinnedRowsContent(_ density: SidebarDensity) throws {
        let (saved, savedMotion) = (DesignSettings.shared.sidebarSections.density, Motion.reduceMotionOverride)
        (DesignSettings.shared.sidebarSections.density, Motion.reduceMotionOverride) = (density, true)
        defer { (DesignSettings.shared.sidebarSections.density, Motion.reduceMotionOverride) = (saved, savedMotion) }
        let h = Harness()
        defer { h.window.orderOut(nil) }
        let pinned = try h.pinnedRow(Self.pins[0])
        let ink = try #require(pinned.pinInkFrame, "the pinned workspace row draws no pin")
        let pin = h.list.convert(ink, from: pinned)
        let pinnedFrame = h.inList(pinned)
        let unpinned = try h.workspaceRow("w3")
        // An unpinned row's leading slot: its icon, or where its title starts without one.
        let content = h.list.convert(unpinned.icon.frame, from: unpinned)
        let unpinnedFrame = h.inList(unpinned)
        #expect(abs(pin.minX - content.minX) < 0.5, "the pin's ink starts at \(pin.minX), an unpinned row's content at \(content.minX)")
        #expect(abs((pin.midY - pinnedFrame.minY) - (content.midY - unpinnedFrame.minY)) < 0.5,
                "the pin centers \(pin.midY - pinnedFrame.minY) pt into its row, an unpinned row's content \(content.midY - unpinnedFrame.minY) pt")
        #expect(abs(pinnedFrame.height - unpinnedFrame.height) < 0.01)
        // The pinned row's title still starts after its pin.
        #expect(h.list.convert(pinned.titleFrame, from: pinned).minX >= pin.maxX)
    }
}

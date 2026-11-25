import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// https://github.com/manaflow-ai/cmux/issues/56146: a workspace pinned inside a sidebar group ("Cloud startup time to
/// first token" in the group "cmux next cloud") drew no pin at rest, so it looked unpinned. Pinned-ness was a property of
/// where a row draws (the Pinned band's leading pin), never of the workspace: a grouped row (`WorkspaceRowView`) had no pin
/// mark at all, and the band's rows lost theirs when they had a favicon (https://github.com/manaflow-ai/cmux/issues/42431,
/// `PinnedRowsShareHomeColumnTests`). The contract here: the document's in-group pin reaches the row
/// (`SidebarWorkspace.isPinnedInGroup`), survives a row patch and clears on unpin; and the row draws its pin mark at every
/// density, with or without its own icon or status, beside them, never over them; an unpinned sibling draws none.
@MainActor @Suite(.serialized, .closesItsWindows) struct GroupedPinnedRowShowsPinTests {
    static let session = "s-local"
    static let machine = "sec_m_s-local"

    static func ref(_ id: String) -> SidebarDocWorkspaceRef { SidebarDocWorkspaceRef(sessionID: session, workspaceID: id) }
    static func ws(_ id: String) -> SidebarWorkspace { SidebarWorkspace(id: WorkspaceID(id), title: id) }

    /// This Mac: group `gm` (`ws-1` pinned in it when `pinned`, `ws-2`), loose `ws-3` carrying a stale mark.
    static func projection(pinned: Bool) -> SidebarDocProjection {
        let records = SidebarDocRecords(sections: [
            machine: SidebarDocSection(id: machine, kind: .machine(session: session)),
        ], items: [
            "itm_gm": SidebarDocItem(id: "itm_gm", section: machine, body: .group(name: "cmux next cloud", color: nil, icon: nil, collapsed: false)),
            "itm_1": SidebarDocItem(id: "itm_1", section: machine, parent: "itm_gm", body: .workspace(ref("ws-1")), pinnedInGroup: pinned),
            "itm_2": SidebarDocItem(id: "itm_2", section: machine, parent: "itm_gm", body: .workspace(ref("ws-2"))),
            "itm_3": SidebarDocItem(id: "itm_3", section: machine, body: .workspace(ref("ws-3")), pinnedInGroup: true),
        ])
        let rows = [
            SidebarDocRow(key: "itm_gm", kind: "group", section: machine, item: "itm_gm"),
            SidebarDocRow(key: "itm_1", kind: "item", section: machine, parent: "itm_gm", depth: 1, item: "itm_1", ref: ref("ws-1")),
            SidebarDocRow(key: "itm_2", kind: "item", section: machine, parent: "itm_gm", depth: 1, item: "itm_2", ref: ref("ws-2")),
            SidebarDocRow(key: "itm_3", kind: "item", section: machine, item: "itm_3", ref: ref("ws-3")),
        ]
        return SidebarDocProjection(rows: rows, records: records, revision: 1)
    }

    static func raw() -> [SidebarSection] {
        [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            .group(SidebarGroup(id: GroupID("itm_gm"), name: "cmux next cloud", workspaces: [ws("ws-1"), ws("ws-2")])), .workspace(ws("ws-3")),
        ])]
    }

    static let drag = SidebarDocDrag(item: { key in
        if case let .workspace(id) = key { return "itm_" + id.rawValue.dropFirst(3) }
        return nil
    }, section: { id in id == .machine(.local) ? machine : nil }, begin: { _ in [:] }, drop: { _, _ in })

    /// Each row's pin mark, by workspace id.
    static func marks(_ sections: [SidebarSection]) -> [String: Bool] {
        var marks: [String: Bool] = [:]
        for node in sections.flatMap(\.nodes) {
            switch node {
            case .workspace(let workspace): marks[workspace.id.rawValue] = workspace.isPinnedInGroup
            case .group(let group): for workspace in group.workspaces { marks[workspace.id.rawValue] = workspace.isPinnedInGroup }
            case .item: break
            }
        }
        return marks
    }

    @Test func theDocumentsInGroupPinReachesTheRow() {
        let marks = Self.marks(Self.projection(pinned: true).arrange(Self.raw(), drag: Self.drag))
        #expect(marks["ws-1"] == true, "the member pinned in its group is not marked: \(marks)")
        #expect(marks["ws-2"] == false, "an unpinned sibling is marked: \(marks)")
        #expect(marks["ws-3"] == false, "a stale mark on a loose row is not a pin: \(marks)")
    }

    @Test func unpinClearsTheMarkOnAnArrangedList() {
        // A fold passes the shown list back in: the old mark must not stay.
        let once = Self.projection(pinned: true).arrange(Self.raw(), drag: Self.drag)
        let again = Self.projection(pinned: false).arrange(once, drag: Self.drag)
        #expect(Self.marks(again).values.allSatisfy { !$0 }, "\(Self.marks(again))")
    }

    @Test func aRowPatchKeepsThePinMark() {
        // A title or status tick patches the row in place, with no `arrange`: the mark must stay.
        let model = SidebarModel(sections: Self.projection(pinned: true).arrange(Self.raw(), drag: Self.drag))
        var renamed = Self.ws("ws-1")
        renamed.title = "Cloud startup time to first token"
        renamed.activity = .working(progress: nil)
        #expect(model.patchWorkspaces([renamed]))
        #expect(Self.marks(model.sections)["ws-1"] == true)
    }

    // MARK: - The row draws it

    static let pinnedID = WorkspaceID("pin-mark-pinned"), iconID = WorkspaceID("pin-mark-icon"), siblingID = WorkspaceID("pin-mark-sibling")

    /// A group of a pinned text-only row, a pinned row with a favicon and the working spinner, and an unpinned sibling.
    static func sidebar(width: CGFloat) -> (SidebarView, NSWindow) {
        _ = NSApplication.shared
        var pinned = SidebarWorkspace(id: pinnedID, title: "Cloud startup time to first token")
        pinned.isPinnedInGroup = true
        var icon = SidebarWorkspace(id: iconID, title: "Docs", icon: .favicon(PinnedSummaryDensityTests.favicon), activity: .working(progress: nil))
        icon.isPinnedInGroup = true
        let sibling = SidebarWorkspace(id: siblingID, title: "Unpinned sibling", icon: .emoji("🚀"))
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [
            .group(SidebarGroup(id: GroupID("g-pin-mark"), name: "cmux next cloud", workspaces: [pinned, icon, sibling])),
        ])], activeWorkspaceID: siblingID)
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.renderNow()
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        return (sidebar, window)
    }

    static func row(_ sidebar: SidebarView, _ id: WorkspaceID) throws -> WorkspaceRowView {
        let row = try #require(sidebar.list.rowViews[.workspace(id)] as? WorkspaceRowView, "no row for \(id.rawValue)")
        row.needsLayout = true
        row.layoutSubtreeIfNeeded()
        return row
    }

    @Test(arguments: DensityPreset.allCases, [Metrics.sidebarMinWidth, 260])
    func aPinnedGroupMemberDrawsItsPinBesideItsIconAndStatus(_ preset: DensityPreset, width: CGFloat) throws {
        try autoreleasepool {
            Motion.reduceMotionOverride = true
            defer { Motion.reduceMotionOverride = nil }
            try DensityTokens.$scoped.withValue(preset.tokens) {
                let (sidebar, window) = Self.sidebar(width: width)
                defer { window.close() }
                let what = "\(preset.rawValue)/\(Int(width))pt"
                for id in [Self.pinnedID, Self.iconID] {
                    let row = try Self.row(sidebar, id)
                    #expect(!row.pinMark.isHidden && row.pinMark.image != nil && row.pinMark.alphaValue > 0.5,
                            "\(what): \(id.rawValue), pinned in its group, draws no pin")
                    #expect(row.pinMark.frame.width > 0 && row.bounds.contains(row.pinMark.frame),
                            "\(what): \(id.rawValue)'s pin is at \(row.pinMark.frame), outside the row \(row.bounds)")
                    #expect(row.accessibilityLabel()?.contains(Strings.pinned) == true,
                            "\(what): \(id.rawValue)'s label does not say Pinned: \(row.accessibilityLabel() ?? "")")
                }
                // The favicon row keeps its icon and its spinner, and the pin meets neither.
                let icon = try Self.row(sidebar, Self.iconID)
                #expect(!icon.icon.isHidden && icon.icon.frame.width > 0, "\(what): the pinned favicon row lost its favicon")
                #expect(!icon.icon.frame.intersects(icon.pinMark.frame), "\(what): the pin draws over the favicon")
                #expect(!icon.activity.isHidden && icon.activity.alphaValue > 0.5, "\(what): the pinned row lost its status spinner")
                #expect(!icon.activity.frame.intersects(icon.pinMark.frame.insetBy(dx: 0.5, dy: 0.5)),
                        "\(what): the pin \(icon.pinMark.frame) meets the spinner \(icon.activity.frame)")
                #expect(icon.pinMark.frame.minX >= icon.titleFrame.minX, "\(what): the pin sits before the title")
                let sibling = try Self.row(sidebar, Self.siblingID)
                #expect(sibling.pinMark.isHidden, "\(what): the unpinned sibling draws a pin")
            }
        }
    }
}

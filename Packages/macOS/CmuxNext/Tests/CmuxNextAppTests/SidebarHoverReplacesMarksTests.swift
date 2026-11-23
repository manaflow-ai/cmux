import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Leo 2026-11-22: "the cross doesnt replace the blue button. ... it seems like now the blue dot is sticking when i
/// hover. in all cases, the hovered buttons should just replace the other ones." While a row's hover controls show
/// (the ✕, the ⋮, the pin), no status mark draws anywhere in the row's trailing cluster: not the blue dot, the
/// spinner, the error mark, the unread count, the task count or the usage warning triangle (the row's hover card still
/// names each warning). Only what a person points at keeps its place: the pull request badge and roll-up chips beside
/// the controls, the audio button, the drive indicator, the tree fold, and the Cloud mark after the name.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarHoverReplacesMarksTests {
    typealias Marks = SidebarRowCloseClearsMarksTests.Marks

    /// The status marks of `row` still drawn, by name.
    static func statusMarksDrawn(in row: WorkspaceRowView) -> [String] {
        let marks: [(String, NSView?)] = [
            ("unread", row.badge), ("rowBadge", row.rowBadge), ("activity", row.activity), ("prText", row.prBadge),
            ("usageWarning", row.usageWarningMark),
            ("muted", row.mutedMark), ("tabCount", row.tabCount), ("keycap", row.keycap), ("time", row.timeLabel),
            ("presence", row.presenceDots),
            ("agentMark", row.agentMarkVariant == .besideTitle ? nil : row.agentMark),
        ]
        return marks.compactMap { name, view in
            guard let view, !view.isHidden, view.frame.width > 0,
                  SidebarTrailingColumnTests.drawnAlpha(view, below: row) > 0.01 else { return nil }
            return name
        }
    }

    @Test(arguments: Marks.allCases, SidebarRowBadgeStyle.allCases)
    func theHoverControlsReplaceEveryStatusMark(_ marks: Marks, _ style: SidebarRowBadgeStyle) throws {
        Motion.reduceMotionOverride = true // the marks clear at once instead of fading out
        defer { Motion.reduceMotionOverride = nil }
        for spot in SidebarRowCloseSpot.allCases {
            for (pinned, warned) in [(false, false), (true, false), (false, true), (true, true)] {
                try SidebarRowCloseSpotTests.withCloseSpot(spot) {
                    // A warned row draws the usage triangle too: it gives way like every other mark (Mango 2026-11-22,
                    // on Leo's "in all cases").
                    let (sidebar, window) = SidebarRowCloseClearsMarksTests.sidebar(marks, style: style, warned: warned)
                    defer { window.close() }
                    // A pinned row draws the ✕, the ⋮ and Unpin (Leo 2026-11-23, ask c-b5d3e0efb6); an unpinned one the ✕, the ⋮ and Pin.
                    sidebar.list.model.workspacePin = (isPinned: { _ in pinned }, toggle: { _ in })
                    sidebar.list.contextMenuProvider = { _ in NSMenu() }
                    window.orderFrontRegardless()
                    sidebar.renderNow()
                    let row = try #require(sidebar.list.rowViews[.workspace(SidebarRowCloseClearsMarksTests.row)] as? WorkspaceRowView)
                    row.wire(SidebarRowCloseClearsMarksTests.row, in: sidebar.list)
                    row.needsLayout = true
                    row.layoutSubtreeIfNeeded()
                    let resting = Self.statusMarksDrawn(in: row)
                    let titleWidth = row.title.frame.width
                    row.isHovered = true
                    row.layoutSubtreeIfNeeded()
                    let controls = [row.closeButton, row.moreButton, row.pinSlot.made].compactMap(\.self)
                        .filter { !$0.isHidden && $0.alphaValue > 0 }
                    try #require(!controls.isEmpty, "\(spot) pinned \(pinned): no hover control on the hovered row")
                    if warned { try #require(resting.contains("usageWarning"), "\(spot) \(marks): the warned row draws no triangle at rest") }
                    let triangle = row.usageWarningMark.frame
                    #expect(Self.statusMarksDrawn(in: row).isEmpty,
                            "\(spot), \(style), \(marks), pinned \(pinned), warned \(warned): \(Self.statusMarksDrawn(in: row)) still draw beside the hover controls")
                    #expect(row.title.frame.width == titleWidth, "\(spot) \(marks): the title moved on hover (a layout shift)")
                    #expect(row.usageWarningMark.frame == triangle, "\(spot) \(marks): the triangle moved on hover (a layout shift)")
                    // The hover ends: every mark the row drew at rest is back.
                    row.isHovered = false
                    row.layoutSubtreeIfNeeded()
                    #expect(Self.statusMarksDrawn(in: row) == resting, "\(spot) \(marks): \(resting) at rest, \(Self.statusMarksDrawn(in: row)) after the hover")
                }
            }
        }
    }

    /// A pinned workspace's tile (Pinned, a band row): its ⋮ and Unpin replace the blue dot, the spinner, the unread
    /// count and the task count ("2/9"), and all of them come back when the controls go.
    @Test(arguments: [false, true])
    func aWorkspaceTileHidesEveryMarkUnderItsControls(_ unreadDot: Bool) throws {
        let view = SidebarItemRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        var info = SidebarItemInfo(title: "Workspace", symbol: "terminal", badge: unreadDot ? nil : 3)
        info.workspace = CmuxNextSidebar.WorkspaceID("ws")
        info.unreadDot = unreadDot
        info.activity = .working(progress: nil)
        info.taskProgress = SidebarTaskProgress(done: 2, total: 9)
        view.onMore = {}
        view.onUnpin = {}
        view.isPinned = { true }
        view.configure(info, style: .list)
        view.layoutSubtreeIfNeeded()
        let marks: [(String, NSView)] = [("unread", view.badge), ("rowBadge", view.rowBadge), ("activity", view.activity), ("taskCount", view.taskCount)]
        func drawn() -> [String] { marks.filter { !$0.1.isHidden && $0.1.frame.width > 0 && $0.1.alphaValue > 0.01 }.map(\.0) }
        let resting = drawn()
        #expect(resting.contains("taskCount"), "the tile draws no task count at rest")
        view.showsMenu = true // reveals the controls as the pointer does
        view.layoutSubtreeIfNeeded()
        #expect(view.hoverMore.map { !$0.isHidden } == true, "no ⋮ on the revealed tile")
        #expect(view.hoverUnpin.map { !$0.isHidden } == true, "no Unpin on the revealed pinned tile")
        #expect(drawn().isEmpty, "\(drawn()) still draw beside the tile's hover controls")
        view.showsMenu = false
        view.layoutSubtreeIfNeeded()
        #expect(drawn() == resting, "\(resting) at rest, \(drawn()) after the controls went")
    }
}

/// Leo 2026-11-22: "the pin button also doesn't work still it doesnt do anything". The row's pin ran Pin Workspace on
/// the window's selection (the active row, usually pinned already), not on the row it sits on, so a click on another
/// row's pin changed nothing. It runs the action on its own row alone (`closesRowOnly`), as the row's speaker does.
@MainActor @Suite(.serialized)
struct SidebarHoverPinTargetTests {
    @Test func theRowPinActsOnItsOwnRowAlone() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"pin","workspace_key":"pin-home"}"#.utf8))
        let bridge = SidebarBridge(services: services, state: WindowState(record: record))
        var runs: [(target: String?, rowOnly: Bool)] = []
        // Bound outside #expect: its autoclosure is @Sendable and cannot capture the mutable `runs`.
        let bound = services.registry.bind("palette.toggleWorkspacePin", invoke: { invocation in
            runs.append((invocation.target?.id, invocation.closesRowOnly))
        })
        #expect(bound)
        let pin = try #require(bridge.model.workspacePin, "the sidebar offers no row pin")
        pin.toggle(CmuxNextSidebar.WorkspaceID("hovered-row"))
        #expect(runs.count == 1, "the row pin ran Pin Workspace \(runs.count) times")
        #expect(runs.first?.target == "hovered-row", "the row pin targeted \(runs.first?.target ?? "nothing")")
        #expect(runs.first?.rowOnly == true, "the row pin acts on the window's selection, not its own row")
    }
}

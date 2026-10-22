import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-21 (nightly 3a63d6d): the row's x sat in its own rounded box that dented the row's
/// corner, and the pills stopped short of the sidebar's edge. "Bring back the length (so we can
/// have more content per sidebar row) and just do it like dog ears on a book on the top right."
/// A workspace row runs to the list's inset again, and its hover action sits on its top-right corner:
/// the close on a row that can close, the menu on one that cannot (Home). The title keeps the row's
/// full width with or without hover. Leo 2026-10-22 on the folded dog-ear that drew there: "i wanted
/// the hoverable area to just... not have it on the top right corner"; the row's fill now leaves the
/// close's small corner out, with no mask on the row.
@MainActor @Suite(.serialized)
struct WorkspaceRowDogEarTests {
    private static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    private static let longName = "a workspace whose name runs all the way to the end of its row and past it"

    /// A 240-wide list showing `workspace`, with a row menu, and its laid out row.
    private static func row(_ workspace: SidebarWorkspace) throws -> (SidebarListView, WorkspaceRowView) {
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [.workspace(workspace)])])
        let list = SidebarListView(model: model)
        list.contextMenuProvider = { _ in NSMenu() }
        list.frame = NSRect(x: 0, y: 0, width: 240, height: 300)
        list.reload(animated: false)
        let row = try #require(list.rowViews[.workspace(workspace.id)] as? WorkspaceRowView)
        row.layoutSubtreeIfNeeded()
        return (list, row)
    }

    private static func hover(_ list: SidebarListView, _ row: WorkspaceRowView, _ id: WorkspaceID) {
        list.setHovered(.workspace(id))
        row.layoutSubtreeIfNeeded()
    }

    /// The topmost control the row hands a click at `point` (row coordinates) to.
    private static func hit(_ row: WorkspaceRowView, at point: NSPoint) -> NSView? {
        row.hitTest(row.convert(point, to: row.superview))
    }

    @Test func theRowRunsToTheListsInsetOnBothSides() throws {
        let ws = SidebarWorkspace(id: WorkspaceID("ws-length"), title: Self.longName)
        let (list, row) = try Self.row(ws)
        #expect(row.frame.minX > 0)
        #expect(abs((list.bounds.width - row.frame.maxX) - row.frame.minX) < 0.5,
                "the row \(row.frame) stops short of the list's right inset (list width \(list.bounds.width))")
    }

    @Test func theTitleRunsToTheRowsTrailingInsetWithAndWithoutHover() throws {
        let ws = SidebarWorkspace(id: WorkspaceID("ws-title"), title: Self.longName)
        let (list, row) = try Self.row(ws)
        let end = row.bounds.width - SidebarStyle.horizontalInset
        let rest = row.title.frame
        #expect(abs(rest.maxX - end) < 0.5, "at rest the title \(rest) ends short of the row's trailing inset \(end)")
        #expect(row.title.trailingOcclusion == 0)

        Self.hover(list, row, ws.id)
        #expect(row.isHovered)
        #expect(row.title.frame == rest, "hover moved or resized the title: \(rest) -> \(row.title.frame)")
        #expect(row.title.trailingOcclusion == 0, "a hover control covers \(row.title.trailingOcclusion) pt of the title's end")
    }

    @Test func aClosableRowsCloseSitsInTheTopRightCornerAndCloses() throws {
        let ws = SidebarWorkspace(id: WorkspaceID("ws-close"), title: Self.longName)
        let (list, row) = try Self.row(ws)
        #expect(row.closeButton.isHidden || row.closeButton.alphaValue == 0, "the close shows before hover")

        Self.hover(list, row, ws.id)
        let ear = row.closeButton
        #expect(!ear.isHidden && ear.alphaValue == 1, "hover shows no close")
        #expect(row.moreButton.isHidden, "a closable row shows the menu too")
        let side = SidebarCloseNotch.snug.side(dogEar: SidebarStyle.dogEarSide)
        #expect(ear.frame == NSRect(x: row.bounds.maxX - side, y: row.bounds.minY, width: side, height: side),
                "the close \(ear.frame) is not the row's top-right \(side) pt corner \(row.bounds)")
        #expect(side < SidebarStyle.dogEarSide, "the cut is no smaller than the old dog-ear")
        #expect(ear.accessibilityIdentifier() == "cmux.sidebar.workspace.ws-close.close")
        #expect(ear.accessibilityLabel() == Strings.closeButton)
        #expect(ear.isAccessibilityElement())

        // The corner takes the click; next to it (left of it or below it) the click is the row's.
        #expect(Self.hit(row, at: NSPoint(x: ear.frame.midX, y: ear.frame.midY)) === ear, "a click in the corner misses the close")
        #expect(Self.hit(row, at: NSPoint(x: ear.frame.minX - 2, y: ear.frame.midY)) !== ear, "a click left of the corner closes")
        #expect(Self.hit(row, at: NSPoint(x: ear.frame.midX, y: ear.frame.maxY + 2)) !== ear, "a click below the corner closes")

        var closed = false
        row.onClose = { closed = true }
        #expect(ear.accessibilityPerformPress())
        #expect(closed, "pressing the close did not close the workspace")
    }

    /// Leo 2026-10-22: "a smaller top right corner not higlighitng bc the button itself chopped off that
    /// top right". The hover fill covers the row but the close's corner; at rest the row fills whole.
    @Test func theHoverFillLeavesTheClosesCornerOut() throws {
        let ws = SidebarWorkspace(id: WorkspaceID("ws-cut"), title: Self.longName)
        let (list, row) = try Self.row(ws)
        Self.hover(list, row, ws.id)
        row.updateLayer()
        let layer = try #require(row.layer)
        #expect(layer.mask == nil, "something masks the row, and so its close")
        #expect(layer.backgroundColor == nil || layer.backgroundColor?.alpha == 0, "the backing layer still fills the whole row")
        let fill = try #require(Self.shapedFill(row), "the hovered row draws no shaped fill")
        let path = try #require(fill.path)
        let ear = row.closeButton.frame
        #expect(!path.contains(CGPoint(x: ear.midX, y: ear.midY)), "the fill covers the close's corner")
        #expect(!path.contains(CGPoint(x: ear.minX + 1, y: ear.maxY - 1)), "the fill covers the cut's inner corner")
        #expect(path.contains(CGPoint(x: ear.minX - 3, y: 1)), "the fill stops short of the cut along the top")
        #expect(path.contains(CGPoint(x: ear.maxX - 1, y: ear.maxY + 3)), "the fill stops short of the cut on the right")
        #expect(path.contains(CGPoint(x: row.bounds.midX, y: row.bounds.midY)))
        #expect(fill.cornerRadius == layer.cornerRadius && fill.masksToBounds, "the fill loses the row's corners")
        #expect(fill.fillColor != nil && (fill.fillColor?.alpha ?? 1) < 1, "the hover fill is opaque")

        list.setHovered(nil)
        row.layoutSubtreeIfNeeded()
        row.updateLayer()
        #expect(Self.shapedFill(row) == nil, "the cut stays after hover")
    }

    /// Every Debug Settings look (`sidebar.closeNotch`, the gallery's versions) cuts its own corner and
    /// keeps the x where it is.
    @Test(arguments: SidebarCloseNotch.allCases)
    func everyCutLookKeepsTheGlyphInPlace(_ look: SidebarCloseNotch) throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        defer { TunableStore.shared.set(SidebarCloseNotch.tunable.key, nil) }
        try #require(TunableStore.shared.set(SidebarCloseNotch.tunable.key, look.tunableValue) == look.tunableValue)
        let ws = SidebarWorkspace(id: WorkspaceID("ws-\(look.rawValue)"), title: Self.longName)
        let (list, row) = try Self.row(ws)
        Self.hover(list, row, ws.id)
        row.updateLayer()
        let ear = row.closeButton
        let side = look.side(dogEar: SidebarStyle.dogEarSide)
        #expect(ear.frame.size == NSSize(width: side, height: side))
        let glyph = ear.convert(ear.glyphRect, to: row)
        let at = SidebarStyle.dogEarSide * 0.3
        #expect(abs(glyph.midX - (row.bounds.maxX - at)) < 0.5 && abs(glyph.midY - at) < 0.5, "\(look): the x moved to \(glyph)")
        let fill = try #require(Self.shapedFill(row))
        let edge = (fill.sublayers?.first as? CAShapeLayer)?.path
        #expect((edge != nil) == (look == .hairline), "\(look): hairline \(edge != nil)")
        let path = try #require(fill.path)
        // A square cut fills up to its corner; a rounded one leaves the corner's curve clear.
        #expect(path.contains(CGPoint(x: ear.frame.minX - 0.5, y: 0.5)) == (look == .square))
    }

    /// The row's shaped fill while it shows.
    private static func shapedFill(_ row: WorkspaceRowView) -> CAShapeLayer? {
        row.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first { !$0.isHidden }
    }

    /// A control the row shows under the close's corner (on a 24 pt row the tabs chevron, the session
    /// tree's fold or the audio button at the row's end sits partly under it) keeps its clicks and
    /// draws over the close, so a click on it never closes the workspace.
    @Test func aControlUnderTheDogEarKeepsItsClicksAndDrawsOverIt() throws {
        let ws = SidebarWorkspace(id: WorkspaceID("ws-under"), title: Self.longName)
        let (list, row) = try Self.row(ws)
        Self.hover(list, row, ws.id)
        let ear = row.closeButton
        let point = NSPoint(x: ear.frame.midX, y: ear.frame.midY)
        #expect(Self.hit(row, at: point) === ear, "a click on the close misses it")
        for control in [row.disclosureButton, row.treeFoldButton, row.audioButton] {
            control.isHidden = false
            control.alphaValue = 1
            control.frame = NSRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)
            #expect(Self.hit(row, at: point) === control, "a click on \(control.accessibilityLabel() ?? "") under the dog-ear closes the workspace")
            #expect((control.layer?.zPosition ?? 0) > (ear.layer?.zPosition ?? 0),
                    "the dog-ear draws over \(control.accessibilityLabel() ?? ""), which takes the click")
            control.isHidden = true
        }
    }

    @Test func theHomeRowsDogEarOpensTheMenuThere() throws {
        let ws = SidebarWorkspace(id: WorkspaceID("ws-home"), title: "Home", isClosable: false)
        let (list, row) = try Self.row(ws)
        var shown: (NSMenu, PopupAnchor, NSView)?
        list.menuPresenter = { shown = ($0, $1, $2) }

        Self.hover(list, row, ws.id)
        let ear = row.moreButton
        #expect(row.closeButton.isHidden, "the home row shows a close")
        #expect(!ear.isHidden && ear.alphaValue == 1, "the home row shows no menu dog-ear")
        #expect(abs(ear.frame.maxX - row.bounds.maxX) < 0.5 && abs(ear.frame.minY - row.bounds.minY) < 0.5,
                "the menu dog-ear \(ear.frame) is not on the row's top-right corner")
        #expect(ear.accessibilityIdentifier() == "cmux.sidebar.workspace.ws-home.more")
        #expect(ear.accessibilityPerformPress())
        let (_, anchor, view) = try #require(shown, "the menu dog-ear opened no menu")
        #expect(view === row && anchor.rect == ear.frame)
    }

    /// An expanded row's hover Pin keeps the end of the name's line, clear of the unread badge
    /// (which now stays on hover) and of the dog-ear, so a click on the pin never closes.
    @Test func anExpandedRowsPinClearsTheUnreadBadgeAndTheDogEar() throws {
        let id = WorkspaceID("ws-pin")
        let ws = SidebarWorkspace(id: id, title: Self.longName, kind: .terminal, unread: .count(3))
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(Self.machine), nodes: [.workspace(ws)])])
        model.rowBadgeStyle = .trailing
        model.workspacePin = (isPinned: { _ in false }, toggle: { _ in })
        let design = DesignSettings()
        design.sidebarSections.density = .expanded
        let sidebar = SidebarView(model: model, design: design)
        sidebar.contextMenuProvider = { _ in NSMenu() }
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        let row = try #require(sidebar.list.rowViews[.workspace(id)] as? WorkspaceRowView)
        Self.hover(sidebar.list, row, id)
        #expect(row.isExpanded)
        #expect(!row.pinButton.isHidden, "an expanded row shows no hover pin")
        #expect(!row.badge.isHidden && row.badge.alphaValue > 0, "the unread badge hides on hover")
        #expect(!row.pinButton.frame.intersects(row.badge.frame),
                "the pin \(row.pinButton.frame) covers the unread badge \(row.badge.frame)")
        #expect(!row.pinButton.frame.intersects(row.closeButton.frame),
                "the pin \(row.pinButton.frame) runs under the dog-ear \(row.closeButton.frame)")
    }
}

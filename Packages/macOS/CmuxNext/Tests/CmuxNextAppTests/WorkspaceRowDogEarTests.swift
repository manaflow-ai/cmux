import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-21 (nightly 3a63d6d): the row's x sat in its own rounded box that dented the row's
/// corner, and the pills stopped short of the sidebar's edge. "Bring back the length (so we can
/// have more content per sidebar row) and just do it like dog ears on a book on the top right."
/// A workspace row runs to the list's inset again, and its hover action is a dog-ear folded over
/// its top-right corner: the close on a row that can close, the menu on one that cannot (Home).
/// The title keeps the row's full width with or without hover, and the row keeps its one corner
/// radius with no mask or box cut into it.
@MainActor
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

    @Test func aClosableRowsDogEarClosesFromTheTopRightCorner() throws {
        let ws = SidebarWorkspace(id: WorkspaceID("ws-close"), title: Self.longName)
        let (list, row) = try Self.row(ws)
        #expect(row.closeButton.isHidden || row.closeButton.alphaValue == 0, "the dog-ear shows before hover")

        Self.hover(list, row, ws.id)
        let ear = row.closeButton
        #expect(!ear.isHidden && ear.alphaValue == 1, "hover shows no dog-ear")
        #expect(row.moreButton.isHidden, "a closable row shows the menu too; its dog-ear is the close")
        #expect(abs(ear.frame.maxX - row.bounds.maxX) < 0.5 && abs(ear.frame.minY - row.bounds.minY) < 0.5,
                "the dog-ear \(ear.frame) is not on the row's top-right corner \(row.bounds)")
        #expect(abs(ear.frame.width - SidebarStyle.dogEarSide) < 0.5 && abs(ear.frame.height - SidebarStyle.dogEarSide) < 0.5)
        #expect(ear.accessibilityIdentifier() == "cmux.sidebar.workspace.ws-close.close")
        #expect(ear.accessibilityLabel() == Strings.closeButton)
        #expect(ear.isAccessibilityElement())

        // The fold takes the click; the rest of its square is the row's, so a click on the
        // title's end never closes the workspace.
        let side = SidebarStyle.dogEarSide
        #expect(Self.hit(row, at: NSPoint(x: ear.frame.maxX - side * 0.2, y: ear.frame.minY + side * 0.2)) === ear,
                "a click inside the fold misses it")
        #expect(Self.hit(row, at: NSPoint(x: ear.frame.minX + side * 0.2, y: ear.frame.maxY - side * 0.2)) !== ear,
                "a click below the fold's crease closes the workspace")

        var closed = false
        row.onClose = { closed = true }
        #expect(ear.accessibilityPerformPress())
        #expect(closed, "pressing the dog-ear did not close the workspace")
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

    @Test func theRowKeepsOneCornerRadiusAndTheDogEarFollowsIt() throws {
        let ws = SidebarWorkspace(id: WorkspaceID("ws-corner"), title: Self.longName)
        let (list, row) = try Self.row(ws)
        Self.hover(list, row, ws.id)
        let layer = try #require(row.layer)
        #expect(layer.mask == nil, "something masks the row's shape")
        #expect(layer.cornerRadius == SidebarStyle.rowCornerRadius)
        #expect(layer.maskedCorners == [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner])
        let ear = row.closeButton
        // No box of its own: the old x painted a rounded hover fill that dented the row's corner.
        #expect(ear.layer?.backgroundColor == nil && (ear.layer?.cornerRadius ?? 0) == 0)
        #expect(ear.cornerRadius == SidebarStyle.rowCornerRadius)

        // Drawn: the fold fills the triangle, leaves the row's rounded corner and the square's
        // lower-left half clear.
        ear.isPointerOnFold = true
        let rep = try #require(ear.bitmapImageRepForCachingDisplay(in: ear.bounds))
        ear.cacheDisplay(in: ear.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / ear.bounds.width
        func alpha(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
            rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.alphaComponent ?? 0
        }
        let side = ear.bounds.width
        #expect(alpha(side * 0.55, side * 0.08) > 0, "the fold draws nothing along the row's top edge")
        #expect(alpha(side * 0.1, side * 0.9) == 0, "the fold fills its square's lower-left half")
        #expect(alpha(side - 0.5, 0.5) == 0, "the fold squares off the row's rounded corner")
    }
}

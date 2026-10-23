import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-21: "Bring back the length ... and just do it like dog ears on a book on the top right";
/// 2026-10-22: "a smaller top right corner not higlighitng bc the button itself chopped off that top
/// right". Rows run to the list's inset, and the hover close sits in a corner the row's fill leaves out.
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

    /// Runs `body` with `sidebar.closeNotch` set to `look`, then clears it. The tunables watch caches
    /// the values rows read, so each set is followed by its refresh, which the app runs one hop later.
    private static func withLook(_ look: SidebarCloseNotch, _ body: () throws -> Void) throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let key = SidebarCloseNotch.tunable.key
        defer {
            TunableStore.shared.set(key, nil)
            SidebarTunablesWatch.shared.changed()
        }
        TunableStore.shared.set(key, look.tunableValue)
        try #require(SidebarCloseNotch.tunable.value == look)
        SidebarTunablesWatch.shared.changed()
        try body()
    }

    /// The center of `ear`'s glyph, in `row`'s coordinates.
    private static func glyphCenter(_ ear: SidebarDogEarButton, in row: WorkspaceRowView) -> NSPoint {
        let glyph = ear.convert(ear.glyphRect, to: row)
        return NSPoint(x: glyph.midX, y: glyph.midY)
    }

    /// The cut's square side and its fillet radius in `row` for `look`.
    private static func cut(_ look: SidebarCloseNotch, _ row: WorkspaceRowView) -> (side: CGFloat, r: CGFloat) {
        let side = look.side(dogEar: SidebarStyle.dogEarSide)
        let radius = look.cornerRadius(rowRadius: row.layer?.cornerRadius ?? SidebarStyle.rowCornerRadius)
        return (side, max(0, min(radius, side / 2)))
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
        let (side, r) = Self.cut(.snug, row)
        #expect(ear.frame == NSRect(x: row.bounds.maxX - side - r, y: row.bounds.minY, width: side + r, height: side + r),
                "the close \(ear.frame) does not cover the row's top-right \(side) pt cut and its \(r) pt fillets \(row.bounds)")
        #expect(side < SidebarStyle.dogEarSide, "the cut is no smaller than the old dog-ear")
        #expect(ear.accessibilityIdentifier() == "cmux.sidebar.workspace.ws-close.close")
        #expect(ear.accessibilityLabel() == Strings.closeButton)
        #expect(ear.isAccessibilityElement())

        // The corner takes the click; next to it (left of it or below it) the click is the row's.
        #expect(Self.hit(row, at: Self.glyphCenter(ear, in: row)) === ear, "a click on the x misses the close")
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
        let (side, _) = Self.cut(.snug, row)
        let left = row.bounds.maxX - side
        #expect(!path.contains(Self.glyphCenter(row.closeButton, in: row)), "the fill covers the close's x")
        #expect(!path.contains(CGPoint(x: left + 0.5, y: 0.5)), "the fill covers the cut's top-left")
        #expect(path.contains(CGPoint(x: left - 6, y: 1)), "the fill stops short of the cut along the top")
        #expect(path.contains(CGPoint(x: row.bounds.maxX - 1, y: side + 6)), "the fill stops short of the cut on the right")
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
        try Self.withLook(look) {
            let ws = SidebarWorkspace(id: WorkspaceID("ws-\(look.rawValue)"), title: Self.longName)
            let (list, row) = try Self.row(ws)
            Self.hover(list, row, ws.id)
            row.updateLayer()
            let ear = row.closeButton
            let (side, r) = Self.cut(look, row)
            #expect(ear.frame.size == NSSize(width: side + r, height: side + r))
            let glyph = Self.glyphCenter(ear, in: row)
            let at = SidebarStyle.dogEarSide * 0.3
            #expect(abs(glyph.x - (row.bounds.maxX - at)) < 0.5 && abs(glyph.y - at) < 0.5, "\(look): the x moved to \(glyph)")
            let fill = try #require(Self.shapedFill(row))
            let edge = (fill.sublayers?.first as? CAShapeLayer)?.path
            #expect((edge != nil) == (look == .hairline), "\(look): hairline \(edge != nil)")
        }
    }

    /// Codex review of 90fc220e: a rounded cut reaches past the close's square (its fillets into the
    /// row's top and right edges), and a click there selected the row. The close takes exactly the
    /// clicks in the drawn cut, in every look.
    @Test(arguments: SidebarCloseNotch.allCases)
    func theClosesHitAreaIsTheDrawnCut(_ look: SidebarCloseNotch) throws {
        try Self.withLook(look) {
            let ws = SidebarWorkspace(id: WorkspaceID("ws-hit-\(look.rawValue)"), title: Self.longName)
            let (list, row) = try Self.row(ws)
            Self.hover(list, row, ws.id)
            row.updateLayer()
            let ear = row.closeButton
            let path = try #require(Self.shapedFill(row)?.path)
            let (side, r) = Self.cut(look, row)
            let left = row.bounds.maxX - side, bottom = row.bounds.minY + side, right = row.bounds.maxX
            var inCut = [NSPoint(x: left + 0.5, y: 0.5), NSPoint(x: right - 0.5, y: bottom - 0.5)]
            var outside = [NSPoint(x: left - r - 0.5, y: 0.5), NSPoint(x: right - 0.5, y: bottom + r + 0.5)]
            if r > 0 {
                // In each fillet, past the square: toward the corner it rounds is the cut, toward the
                // fillet's center is the fill.
                inCut += [NSPoint(x: left - 0.15 * r, y: 0.15 * r), NSPoint(x: right - 0.15 * r, y: bottom + 0.15 * r)]
                outside += [NSPoint(x: left - 0.85 * r, y: 0.85 * r), NSPoint(x: right - 0.85 * r, y: bottom + 0.85 * r)]
            } else {
                outside += [NSPoint(x: left - 0.5, y: 0.5), NSPoint(x: right - 0.5, y: bottom + 0.5)]
            }
            for point in inCut {
                #expect(!path.contains(point), "\(look): \(point) is not in the drawn cut")
                #expect(Self.hit(row, at: point) === ear, "\(look): a click at \(point), in the cut, does not close")
            }
            for point in outside {
                #expect(path.contains(point), "\(look): \(point) is not on the drawn fill")
                #expect(Self.hit(row, at: point) !== ear, "\(look): a click at \(point), on the fill, closes")
            }
        }
    }

    /// Codex review of c80b62d9: only the first hit test checked the cut, and NSButton's tracking fired
    /// on a release anywhere in its frame, which reaches onto the fill past a rounded cut. A press in
    /// the cut released on that fill does nothing; pressed and released in the cut, it closes.
    @Test func aPressReleasedOnTheFillInsideTheFrameDoesNotClose() throws {
        let ws = SidebarWorkspace(id: WorkspaceID("ws-release"), title: Self.longName)
        let (list, row) = try Self.row(ws)
        Self.hover(list, row, ws.id)
        let ear = row.closeButton
        var closes = 0
        row.onClose = { closes += 1 }
        let (side, r) = Self.cut(.snug, row)
        try #require(r > 0, "the default cut has no fillet to release on")
        let inCut = ear.convert(Self.glyphCenter(ear, in: row), from: row)
        let onFill = ear.convert(NSPoint(x: row.bounds.maxX - side - 0.85 * r, y: 0.85 * r), from: row)
        #expect(ear.bounds.contains(onFill) && !ear.cutContains(onFill) && ear.cutContains(inCut))
        func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: ear.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        ear.mouseDown(with: try event(.leftMouseDown, inCut))
        ear.mouseDragged(with: try event(.leftMouseDragged, onFill))
        ear.mouseUp(with: try event(.leftMouseUp, onFill))
        #expect(closes == 0, "a press in the cut released on the fill closed the workspace")
        ear.mouseDown(with: try event(.leftMouseDown, inCut))
        ear.mouseUp(with: try event(.leftMouseUp, inCut))
        #expect(closes == 1, "a click in the cut did not close the workspace")
    }

    /// Codex review of 90fc220e: `sidebar.closeNotch` was read only in layout, so a row on screen kept
    /// its old cut until some other layout. The tunables watch reconfigures the shown rows.
    @Test func changingTheCutLookRelaysOutTheShownRows() async throws {
        let key = SidebarCloseNotch.tunable.key
        try Self.withLook(.snug) {}
        defer {
            TunableStore.shared.set(key, nil)
            SidebarTunablesWatch.shared.changed()
        }
        let ws = SidebarWorkspace(id: WorkspaceID("ws-watch"), title: Self.longName)
        let (list, row) = try Self.row(ws)
        Self.hover(list, row, ws.id)
        let before = row.closeButton.frame
        TunableStore.shared.set(key, SidebarCloseNotch.hitBox.tunableValue)
        // The watch's observation runs one main-actor hop after the set.
        var hops = 0
        while row.closeNotchLook != .hitBox, hops < 100 {
            await Task.yield()
            hops += 1
        }
        #expect(row.closeNotchLook == .hitBox, "the shown row never heard the new look")
        row.layoutSubtreeIfNeeded()
        let (side, r) = Self.cut(.hitBox, row)
        #expect(row.closeButton.frame.size == NSSize(width: side + r, height: side + r) && row.closeButton.frame != before,
                "the shown row kept its old cut \(row.closeButton.frame)")
    }

    /// Codex review of 90fc220e: shown under a pointer that does not move, the close got no enter event
    /// and its x stayed dim. It reads the pointer as it shows.
    @Test func theCloseLightsWhenItShowsUnderAStillPointer() throws {
        let ws = SidebarWorkspace(id: WorkspaceID("ws-still"), title: Self.longName)
        let (list, row) = try Self.row(ws)
        let ear = row.closeButton
        var onGlyph = true
        ear.pointerInWindow = { [unowned ear] in
            onGlyph ? ear.convert(NSPoint(x: ear.glyphRect.midX, y: ear.glyphRect.midY), to: nil) : ear.convert(NSPoint(x: -40, y: 40), to: nil)
        }
        Self.hover(list, row, ws.id)
        #expect(!ear.isHidden && ear.isPointerOn, "the close showed under the pointer with its x dim")

        list.setHovered(nil)
        row.layoutSubtreeIfNeeded()
        #expect(ear.isHidden && !ear.isPointerOn)
        onGlyph = false
        Self.hover(list, row, ws.id)
        #expect(!ear.isHidden && !ear.isPointerOn, "the close lit with the pointer off it")
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
        let point = Self.glyphCenter(ear, in: row)
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

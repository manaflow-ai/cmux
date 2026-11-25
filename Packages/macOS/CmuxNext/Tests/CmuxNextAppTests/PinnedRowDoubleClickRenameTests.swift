import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Lawrence msg 19583: "double clicking pinned workspaces to rename has problem". A pinned row (a Pinned block's
/// workspace row, drawn by the band's `SidebarItemRowView` with its leading pin, or a pinned workspace drawn as a list
/// row) renames in place on a double-click, as an unpinned row does (a944, user 2026-10-31: "double click to rename
/// workspaces must not have layout shift"): the editor's text starts on the title's first glyph, no row moves, the
/// first click switches once as a single click does and starts no drag, and Return sends one rename.
///
/// Each case runs the real ``SidebarView`` (Home and three pinned workspace rows on top, a machine list under them)
/// and delivers the clicks as the window does: to the view the window's hit test finds, mouse-down then mouse-up,
/// with click counts 1 and 2.
@MainActor @Suite(.serialized, .closesItsWindows)
struct PinnedRowDoubleClickRenameTests {
    static let home = LayoutItem(id: LayoutItemID("itm_home"), ref: SidebarLayoutDocument.homeRef)
    static let pins = ["perf", "chromium", "chief"].map { LayoutItem(id: LayoutItemID("itm_pin_\($0)"), ref: .workspace("local:ws-pin-\($0)")) }
    static let pinTitles = ["cmux Performance Lead", "cmux-chromium lead", "Chief TUI + fast iteration"]
    static let loose = ["ws-loose-0", "ws-loose-1", "ws-loose-2"].map(WorkspaceID.init)

    final class Harness {
        let model: SidebarModel
        let sidebar: SidebarView
        let window: NSWindow
        private(set) var intents: [SidebarIntent] = []
        var list: SidebarListView { sidebar.list }

        init(pinnedListRow: WorkspaceID? = nil) {
            _ = NSApplication.shared
            let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, arrangement: .list,
                                    items: [PinnedRowDoubleClickRenameTests.home])
            let pinned = SidebarLayoutDocument.pinnedSection(items: PinnedRowDoubleClickRenameTests.pins)
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            let titles = ["Original cmux-next kickoff prompt", "Sidebar group row alignment", "Restore original cmux look"]
            model = SidebarModel(sections: [
                SidebarSection(kind: .custom(SidebarCustomSection(id: top.id.rawValue)), nodes: []),
                SidebarSection(kind: .custom(SidebarCustomSection(id: pinned.id.rawValue)), nodes: []),
                SidebarSection(kind: .machine(machine), nodes: zip(PinnedRowDoubleClickRenameTests.loose, titles).map { id, title in
                    .workspace(SidebarWorkspace(id: id, title: title))
                }),
            ])
            model.layout = SidebarLayoutDocument(sections: [top, pinned])
            var infos: [LayoutItemID: SidebarItemInfo] = [PinnedRowDoubleClickRenameTests.home.id: SidebarItemInfo(title: "Home", symbol: "house")]
            for (index, (pin, title)) in zip(PinnedRowDoubleClickRenameTests.pins, PinnedRowDoubleClickRenameTests.pinTitles).enumerated() {
                var info = SidebarItemInfo(title: title, symbol: "textformat")
                info.textOnly = true
                info.workspace = WorkspaceID(pin.ref.value.replacingOccurrences(of: "local:", with: ""))
                // The second pin has news: its trailing dot must stay where it is while its name is edited.
                info.unreadDot = index == 1
                infos[pin.id] = info
            }
            model.itemInfo = infos
            model.docDrag = SidebarDocDrag(item: { _ in nil }, section: { _ in nil }, begin: { _ in [:] }, drop: { _, _ in }, adoptRef: { _ in nil })
            if let pinnedListRow { model.workspacePin = (isPinned: { $0 == pinnedListRow }, toggle: { _ in }) }
            sidebar = SidebarView(model: model, design: DesignSettings())
            sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 560)
            window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 260, height: 560), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = sidebar
            window.orderFrontRegardless()
            settle()
            model.onIntent = { [unowned self] intent in intents.append(intent) }
        }

        func close() {
            list.inlineRename.end(commit: false)
            PointerHover.setDebugPointer(nil, in: window)
            window.close()
        }

        func settle() {
            sidebar.renderNow()
            sidebar.needsLayout = true
            sidebar.layoutSubtreeIfNeeded()
            list.reload(animated: false)
            sidebar.layoutSubtreeIfNeeded()
            list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
            for region in list.blockRegions { region.itemViews.values.forEach { $0.layoutSubtreeIfNeeded() } }
        }

        /// The band row that draws pinned item `id`.
        func pin(_ id: LayoutItemID) throws -> SidebarItemRowView {
            let view = try #require(list.blockRegions.lazy.compactMap { $0.itemView(id) }.first, "no block draws \(id.rawValue)")
            view.layoutSubtreeIfNeeded()
            return view
        }

        func clearIntents() { intents = [] }

        /// The pointer rests at `point` (window coordinates), as before a real click: the row under it is hovered.
        func hover(_ point: NSPoint) {
            PointerHover.setDebugPointer(point, in: window)
            settle()
        }

        /// A click at `point` (window coordinates) with click count `count`, delivered as the window delivers it: the
        /// press to the view its hit test finds, the release to the same view.
        func click(at point: NSPoint, count: Int) throws {
            let root = try #require(window.contentView)
            let target = try #require(root.hitTest(root.superview?.convert(point, from: nil) ?? point), "nothing takes a click at \(point)")
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count,
                                                            pressure: type == .leftMouseUp ? 0 : 1))
                if type == .leftMouseDown { target.mouseDown(with: event) } else { target.mouseUp(with: event) }
            }
        }

        func doubleClick(at point: NSPoint) throws {
            try click(at: point, count: 1)
            try click(at: point, count: 2)
        }

        var field: NSTextField? { list.inlineRename.session?.field }

        /// Every drag card (`DragLiftView`) in the window.
        var lifts: [DragLiftView] {
            var found: [DragLiftView] = []
            var stack: [NSView] = window.contentView.map { [$0] } ?? []
            while let view = stack.popLast() {
                if let lift = view as? DragLiftView { found.append(lift) }
                stack.append(contentsOf: view.subviews)
            }
            return found
        }

        /// Where every pinned band row and every list row sits in the window now.
        var frames: [String: NSRect] {
            var frames: [String: NSRect] = [:]
            for pin in PinnedRowDoubleClickRenameTests.pins {
                if let view = try? self.pin(pin.id) { frames[pin.id.rawValue] = view.convert(view.bounds, to: nil) }
            }
            for (key, view) in list.rowViews where list.displayed.row(for: key) != nil {
                frames["\(key)"] = view.convert(view.bounds, to: nil)
            }
            return frames
        }

        /// Types `text` in the open editor and presses Return.
        func type(_ text: String) throws {
            let field = try #require(field, "no rename editor is open")
            let editor = try #require(field.currentEditor() as? NSTextView, "the rename editor is not editing")
            field.stringValue = text
            _ = list.inlineRename.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        }

        /// Presses Escape in the open editor.
        func escape() throws {
            let field = try #require(field, "no rename editor is open")
            let editor = try #require(field.currentEditor() as? NSTextView, "the rename editor is not editing")
            _ = list.inlineRename.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        }

        /// The workspace switches and selections the intents since the last clear asked for.
        var switches: [String] {
            intents.compactMap { intent in
                switch intent {
                case let .activateItem(id, _): "activate \(id.rawValue)"
                case let .select(id): "select \(id.rawValue)"
                default: nil
                }
            }
        }

        var renames: [(WorkspaceID, String)] {
            intents.compactMap { if case let .rename(id, text) = $0 { (id, text) } else { nil } }
        }
    }

    /// Where a band row's title (a chrome label) draws its first glyph on its baseline, in window coordinates.
    static func titlePen(_ row: SidebarItemRowView) -> NSPoint {
        let title = row.title
        return row.convert(NSPoint(x: title.frame.minX + title.alignmentRectInsets.left, y: title.frame.minY + title.firstBaselineOffsetFromTop),
                           to: nil)
    }

    /// Where a workspace row's title (a marquee label) draws its first glyph on its baseline, in window coordinates.
    static func titlePen(_ row: WorkspaceRowView, scale: CGFloat) -> NSPoint {
        let frame = row.title.frame
        return row.convert(NSPoint(x: frame.minX, y: frame.minY + (row.title.font.ascender * scale).rounded() / scale), to: nil)
    }

    static func editorPen(_ field: NSTextField) throws -> NSPoint {
        let pen = try SidebarRenameInPlaceTests.editorPen(field, in: field)
        return field.convert(pen, to: nil)
    }

    static func expectSameFrames(_ a: [String: NSRect], _ b: [String: NSRect], _ when: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(Set(a.keys) == Set(b.keys), "\(when): the shown rows changed", sourceLocation: sourceLocation)
        for (key, frame) in a {
            guard let other = b[key] else { continue }
            #expect(frame == other, "\(when): row \(key) moved or resized from \(frame) to \(other)", sourceLocation: sourceLocation)
        }
    }

    init() { Motion.reduceMotionOverride = true }

    /// What a single click on the row asks for (the switch the double-click's first click must match).
    static func singleClickSwitches(at point: NSPoint, pinnedListRow: WorkspaceID? = nil) throws -> [String] {
        let harness = Harness(pinnedListRow: pinnedListRow)
        defer { harness.close() }
        harness.hover(point)
        harness.clearIntents()
        try harness.click(at: point, count: 1)
        return harness.switches
    }

    /// Each pinned band row, the one with a trailing dot too.
    @Test(arguments: [0, 1, 2]) func aDoubleClickRenamesAPinnedBandRowInPlace(_ index: Int) throws {
        defer { Motion.reduceMotionOverride = nil }
        let pinItem = Self.pins[index]
        let workspace = WorkspaceID(pinItem.ref.value.replacingOccurrences(of: "local:", with: ""))
        let harness = Harness()
        defer { harness.close() }
        var row = try harness.pin(pinItem.id)
        let title = row.convert(row.titleFrame, to: nil)
        let point = NSPoint(x: title.minX + 6, y: title.midY)
        let single = try Self.singleClickSwitches(at: point)
        #expect(single == ["activate \(pinItem.id.rawValue)"], "a single click on the pinned row asked for \(single)")

        harness.hover(point)
        row = try harness.pin(pinItem.id)
        let before = harness.frames
        let pen = Self.titlePen(row)
        let font = row.title.font
        let more = row.hoverMore.map { $0.convert($0.bounds, to: nil) }
        let dot = row.rowBadge.isHidden ? nil : row.convert(row.rowBadge.frame, to: nil)
        harness.clearIntents()

        try harness.doubleClick(at: point)

        let field = try #require(harness.field, "\(Self.pinTitles[index]): a double-click on the pinned row opened no rename editor")
        #expect(field.stringValue == Self.pinTitles[index], "the editor holds \(field.stringValue)")
        #expect(field.font == font, "the editor's font \(String(describing: field.font)) is not the title's \(String(describing: font))")
        let scale = harness.window.backingScaleFactor
        let editing = try Self.editorPen(field)
        #expect(SidebarRenameInPlaceTests.samePixel(editing, pen, scale: scale), "the editor's text starts at \(editing), the title's at \(pen)")
        #expect(harness.list.drag == nil && harness.lifts.isEmpty, "the double-click lifted or dragged the row")
        #expect(harness.list.blockRegions.allSatisfy { $0.docPressedItem == nil && $0.reorder == nil }, "a band press is still held")
        #expect(harness.switches == single, "the double-click asked for \(harness.switches), a single click for \(single)")
        Self.expectSameFrames(before, harness.frames, "while renaming")
        let editingRow = try harness.pin(pinItem.id)
        #expect(editingRow === row, "the pinned row's view was replaced while renaming")
        if let more {
            #expect(editingRow.hoverMore.map { $0.convert($0.bounds, to: nil) } == more, "the more button moved while renaming")
            #expect(field.frame.maxX <= editingRow.convert(editingRow.hoverMore!.frame, to: field.superview).minX,
                    "the editor runs over the more button")
        }
        if let dot { #expect(editingRow.convert(editingRow.rowBadge.frame, to: nil) == dot, "the trailing dot moved while renaming") }

        harness.clearIntents()
        try harness.type("Renamed pin")
        #expect(harness.field == nil, "Return left the editor open")
        let renames = harness.renames
        #expect(renames.count == 1 && renames.first?.0 == workspace && renames.first?.1 == "Renamed pin",
                "Return sent \(renames), not one rename of \(workspace.rawValue)")
        harness.settle()
        let after = try harness.pin(pinItem.id)
        #expect(!after.title.isHidden && after.title.alphaValue == 1, "the pinned row's title stays hidden after the rename")
        Self.expectSameFrames(before, harness.frames, "after renaming")
    }

    @Test func escapeEndsAPinnedRowsRenameAndShowsItsTitle() throws {
        defer { Motion.reduceMotionOverride = nil }
        let harness = Harness()
        defer { harness.close() }
        let row = try harness.pin(Self.pins[0].id)
        let title = row.convert(row.titleFrame, to: nil)
        let point = NSPoint(x: title.minX + 6, y: title.midY)
        harness.hover(point)
        try harness.doubleClick(at: point)
        _ = try #require(harness.field, "a double-click on the pinned row opened no rename editor")
        harness.clearIntents()
        try harness.escape()
        #expect(harness.field == nil, "Escape left the editor open")
        #expect(harness.renames.isEmpty, "Escape renamed: \(harness.renames)")
        let shown = try harness.pin(Self.pins[0].id)
        #expect(!shown.title.isHidden && shown.titleText == Self.pinTitles[0], "the title does not show after Escape")
    }

    /// The comparison: an unpinned list row, and a pinned workspace drawn as a list row, rename the same way.
    @Test(arguments: [false, true]) func aDoubleClickRenamesAListRowInPlace(_ pinned: Bool) throws {
        defer { Motion.reduceMotionOverride = nil }
        let id = Self.loose[1]
        let harness = Harness(pinnedListRow: pinned ? id : nil)
        defer { harness.close() }
        var row = try #require(harness.list.rowViews[.workspace(id)] as? WorkspaceRowView)
        row.layoutSubtreeIfNeeded()
        let title = row.convert(row.title.frame, to: nil)
        let point = NSPoint(x: title.minX + 6, y: title.midY)
        let single = try Self.singleClickSwitches(at: point, pinnedListRow: pinned ? id : nil)
        #expect(single == ["select \(id.rawValue)"], "a single click on the row asked for \(single)")

        harness.hover(point)
        row = try #require(harness.list.rowViews[.workspace(id)] as? WorkspaceRowView)
        row.layoutSubtreeIfNeeded()
        let before = harness.frames
        let scale = harness.window.backingScaleFactor
        let pen = Self.titlePen(row, scale: scale)
        harness.clearIntents()

        try harness.doubleClick(at: point)

        let field = try #require(harness.field, "pinned \(pinned): a double-click on the list row opened no rename editor")
        let editing = try Self.editorPen(field)
        #expect(SidebarRenameInPlaceTests.samePixel(editing, pen, scale: scale), "the editor's text starts at \(editing), the title's at \(pen)")
        #expect(harness.list.drag == nil && harness.lifts.isEmpty, "the double-click lifted or dragged the row")
        #expect(harness.switches == single, "the double-click asked for \(harness.switches), a single click for \(single)")
        Self.expectSameFrames(before, harness.frames, "while renaming")

        harness.clearIntents()
        try harness.type("Renamed row")
        let renames = harness.renames
        #expect(renames.count == 1 && renames.first?.0 == id && renames.first?.1 == "Renamed row",
                "Return sent \(renames), not one rename of \(id.rawValue)")
    }
}

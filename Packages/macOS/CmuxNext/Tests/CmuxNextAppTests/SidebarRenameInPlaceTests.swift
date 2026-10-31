import AppKit
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// User 2026-10-31: "double click to rename workspaces must not have layout shift. should also
/// work for renaming groups too." A double-click on a workspace row or on a group header's name
/// opens the editor in the title's place: its text starts on the title's first glyph and
/// baseline, in the title's font, and no row moves or resizes before, during or after the edit.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarRenameInPlaceTests {
    /// A sidebar in a window with two groups of one workspace each.
    final class Harness {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let sidebar: SidebarView
        let groups: [GroupID]
        private(set) var intents: [SidebarIntent] = []

        init() throws {
            let (sidebar, ids) = try GroupPaletteDefaultTests.sidebar([.blue, .red])
            (self.sidebar, groups) = (sidebar, ids)
            window.isReleasedWhenClosed = false
            sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
            window.contentView?.addSubview(sidebar)
            window.orderFrontRegardless()
            sidebar.list.reload(animated: false)
            sidebar.layoutSubtreeIfNeeded()
            sidebar.list.model.onIntent = { [unowned self] intent in intents.append(intent) }
        }

        func close() {
            sidebar.list.inlineRename.end(commit: false)
            sidebar.list.groupEditor.hide()
            sidebar.list.groupEditor.bubble?.close()
            window.close()
        }

        var list: SidebarListView { sidebar.list }

        /// Every realized row's frame in the list, by key.
        var rowFrames: [SidebarRowKey: NSRect] {
            list.layoutSubtreeIfNeeded()
            return list.rowViews.mapValues(\.frame)
        }

        /// Two plain clicks at `point` (list coordinates), the second with a click count of 2.
        func doubleClick(at point: NSPoint) throws {
            let location = list.convert(point, to: nil)
            for count in [1, 2] {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                               clickCount: count, pressure: type == .leftMouseUp ? 0 : 1))
                    if type == .leftMouseDown { list.mouseDown(with: event) } else { list.mouseUp(with: event) }
                }
            }
        }

        var field: NSTextField? { list.inlineRename.session?.field }
    }

    /// Where `field`'s editor draws its first glyph on its baseline, in `view`'s coordinates.
    static func editorPen(_ field: NSTextField, in view: NSView) throws -> NSPoint {
        let editor = try #require(field.currentEditor() as? NSTextView, "the rename field is not editing")
        let inset = editor.textContainerOrigin
        let point: NSPoint
        if let manager = editor.textLayoutManager {
            manager.ensureLayout(for: manager.documentRange)
            let fragment = try #require(manager.textLayoutFragment(for: manager.documentRange.location))
            let line = try #require(fragment.textLineFragments.first)
            point = NSPoint(x: inset.x + fragment.layoutFragmentFrame.minX + line.typographicBounds.minX + line.glyphOrigin.x,
                            y: inset.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y)
        } else {
            let manager = try #require(editor.layoutManager)
            let line = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            let glyph = manager.location(forGlyphAt: 0)
            point = NSPoint(x: inset.x + line.minX + glyph.x, y: inset.y + line.minY + glyph.y)
        }
        return view.convert(point, from: editor)
    }

    /// A workspace title (a marquee label) draws at its frame's edge, its baseline one ascender
    /// (on a whole pixel) below its top.
    static func titlePen(_ row: WorkspaceRowView, in list: NSView, scale: CGFloat) -> NSPoint {
        let frame = row.title.frame
        let baseline = (row.title.font.ascender * scale).rounded() / scale
        return list.convert(NSPoint(x: frame.minX, y: frame.minY + baseline), from: row)
    }

    /// A group name (a chrome label) draws its padding in from its frame, on its first baseline.
    static func namePen(_ header: GroupHeaderRowView, in list: NSView) -> NSPoint {
        let name = header.name
        return list.convert(NSPoint(x: name.frame.minX + name.alignmentRectInsets.left,
                                    y: name.frame.minY + name.firstBaselineOffsetFromTop), from: header)
    }

    /// AppKit puts a field editor on whole device pixels, so a title on a half point (a 1x test window) can land
    /// half a pixel off; on a 2x screen the text lands exactly on the title's.
    static func samePixel(_ a: NSPoint, _ b: NSPoint, scale: CGFloat) -> Bool {
        let limit = 0.5 / max(scale, 1) + 0.001
        return abs(a.x - b.x) <= limit && abs(a.y - b.y) <= limit
    }

    static func expectSame(_ a: [SidebarRowKey: NSRect], _ b: [SidebarRowKey: NSRect], _ when: String) {
        #expect(Set(a.keys) == Set(b.keys), "\(when): the shown rows changed")
        for (key, frame) in a {
            guard let other = b[key] else { continue }
            #expect(frame == other, "\(when): row \(key) moved from \(frame) to \(other)")
        }
    }

    @Test func aDoubleClickRenamesAWorkspaceInPlace() throws {
        let harness = try Harness()
        defer { harness.close() }
        let list = harness.list
        let id = try #require(list.workspaces.keys.first)
        let row = try #require(list.rowViews[.workspace(id)] as? WorkspaceRowView)
        row.layoutSubtreeIfNeeded()
        let scale = harness.window.backingScaleFactor
        let before = harness.rowFrames
        let pen = Self.titlePen(row, in: list, scale: scale)
        let font = row.title.font

        let title = list.convert(row.title.frame, from: row)
        try harness.doubleClick(at: NSPoint(x: title.minX + 4, y: title.midY))
        let field = try #require(harness.field, "a double-click on the workspace did not open the rename")
        Self.expectSame(before, harness.rowFrames, "while renaming")
        #expect(field.font == font, "the editor's font \(String(describing: field.font)) is not the title's \(font)")
        let editing = try Self.editorPen(field, in: list)
        #expect(Self.samePixel(editing, pen, scale: scale), "the editor's text starts at \(editing), the title's at \(pen)")

        list.inlineRename.end(commit: false)
        Self.expectSame(before, harness.rowFrames, "after renaming")
    }

    @Test func aDoubleClickOnAGroupNameRenamesItInPlace() async throws {
        let harness = try Harness()
        defer { harness.close() }
        let list = harness.list
        let group = harness.groups[0]
        let header = try #require(list.rowViews[.group(group)] as? GroupHeaderRowView)
        header.layoutSubtreeIfNeeded()
        let before = harness.rowFrames
        let pen = Self.namePen(header, in: list)
        let font = header.titleFont

        let name = list.convert(header.name.frame, from: header)
        try harness.doubleClick(at: NSPoint(x: name.minX + 4, y: name.midY))
        #expect(!list.groupEditor.isVisible, "a double-click on the group's name opened the group editor")
        let field = try #require(harness.field, "a double-click on the group's name did not open the rename")
        Self.expectSame(before, harness.rowFrames, "while renaming")
        let toggles = harness.intents.filter { if case .toggleCollapse = $0 { true } else { false } }
        #expect(toggles.isEmpty, "the double-click folded the group: \(harness.intents)")
        #expect(field.font == font)
        let editing = try Self.editorPen(field, in: list)
        #expect(Self.samePixel(editing, pen, scale: harness.window.backingScaleFactor),
                "the editor's text starts at \(editing), the name's at \(pen)")

        field.stringValue = "Renamed"
        list.inlineRename.end(commit: true, byKeyboard: true)
        #expect(harness.intents.contains { if case .renameGroup(group, "Renamed") = $0 { true } else { false } })
        Self.expectSame(before, harness.rowFrames, "after renaming")
    }
}

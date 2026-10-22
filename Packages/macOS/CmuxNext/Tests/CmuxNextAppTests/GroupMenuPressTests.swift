import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-21 (u9795), on the sidebar group header's ⋮ editor: "i want to be able to
/// mousedown on the 3 dots, mousemove, then mouseup to select what i want. need to handle the
/// rename text input case better too… and if i spam it a lot, i think the animations are bad.
/// so maybe no entry animation, yes exit animation". The editor opened on mouse-up, with the
/// name field focused and its text selected, and grew in on a spring that a fast reopen restarted.
/// Now one press opens it at mouse-down, a drag highlights, a release on an item runs it and a
/// release on nothing keeps it open; the name stays untouched until a click into it or typing,
/// Escape puts it back; it appears in one frame and only fades out.
@MainActor @Suite(.serialized) struct GroupMenuPressTests {
    /// A sidebar with one group in a never-shown window; every editor row and intent recorded.
    final class Log {
        var items: [String] = []
        var intents: [SidebarIntent] = []
    }

    static func fixture() throws -> (SidebarView, GroupID, NSWindow, GroupHeaderRowView, Log) {
        let (sidebar, id, window) = try SidebarMenuAnchorTests.sidebar(width: 300)
        let log = Log()
        sidebar.list.onGroupEditorItem = { _, item in log.items.append(item) }
        sidebar.list.model.onIntent = { log.intents.append($0) }
        let header = try #require(sidebar.list.rowViews[.group(id)] as? GroupHeaderRowView)
        header.isHovered = true
        header.layoutSubtreeIfNeeded()
        return (sidebar, id, window, header, log)
    }

    /// The middle of `view` (in the editor bubble) in `window`'s coordinates.
    static func point(of view: NSView, in window: NSWindow) throws -> NSPoint {
        let bubble = try #require(view.window)
        let screen = bubble.convertPoint(toScreen: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
        return window.convertPoint(fromScreen: screen)
    }

    static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 7, clickCount: 1, pressure: 1))
    }

    static func key(_ characters: String, code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    /// Presses the more button and feeds the press the drags and release `steps` builds once
    /// the editor is up (they need its rows on screen).
    static func press(_ header: GroupHeaderRowView, in window: NSWindow,
                      steps: @escaping (SidebarGroupEditorPanel) throws -> [NSEvent]) throws {
        let more = header.moreButton
        let down = try mouse(.leftMouseDown, at: more.convert(NSPoint(x: more.bounds.midX, y: more.bounds.midY), to: nil), in: window)
        var queue: [NSEvent]?
        var failure: (any Error)?
        let list = try #require(header.enclosingList, "the header is not in a sidebar list")
        more.nextPressEvent = { [weak list] _ in
            if queue == nil {
                guard let bubble = list?.groupEditor.bubble else { return nil }
                do { queue = try steps(bubble) } catch { failure = error; queue = [] }
            }
            return queue?.isEmpty == false ? queue?.removeFirst() : nil
        }
        more.mouseDown(with: down)
        if let failure { throw failure }
    }

    static func row(_ id: String, in bubble: SidebarGroupEditorPanel) throws -> SidebarGroupEditorRow {
        try #require(bubble.rows.first { $0.item.id == id }, "no \(id) row")
    }

    @Test func pressDragReleaseRunsTheItemUnderThePointer() throws {
        let (sidebar, id, window, header, log) = try Self.fixture()
        defer { sidebar.list.groupEditor.hide(); window.close() }
        try Self.press(header, in: window) { bubble in
            #expect(sidebar.list.groupEditor.shownGroup == id, "the editor did not open at mouse-down")
            let pin = try Self.point(of: Self.row("workspaceGroup.togglePin", in: bubble), in: window)
            let top = try Self.point(of: Self.row("workspaceGroup.moveToTop", in: bubble), in: window)
            return [try Self.mouse(.leftMouseDragged, at: pin, in: window), try Self.mouse(.leftMouseDragged, at: top, in: window),
                    try Self.mouse(.leftMouseUp, at: top, in: window)]
        }
        #expect(log.items == ["workspaceGroup.moveToTop"], "the release ran \(log.items)")
        #expect(sidebar.list.groupEditor.shownGroup == nil, "running a row leaves the editor open")
    }

    @Test func aDragHighlightsWhatIsUnderThePointerOnly() throws {
        let (sidebar, _, window, header, _) = try Self.fixture()
        defer { sidebar.list.groupEditor.hide(); window.close() }
        var seen: [NSView?] = []
        try Self.press(header, in: window) { bubble in
            let close = try Self.row("workspaceGroup.closeWorkspaces", in: bubble)
            let swatch = try #require(bubble.swatches.last)
            let a = try Self.point(of: close, in: window), b = try Self.point(of: swatch, in: window)
            let outside = NSPoint(x: -500, y: -500)
            bubble.pressMoved(to: window.convertPoint(toScreen: a))
            seen.append(bubble.highlighted)
            #expect(close.isHighlighted)
            bubble.pressMoved(to: window.convertPoint(toScreen: b))
            seen.append(bubble.highlighted)
            #expect(swatch.isHighlighted && !close.isHighlighted, "two highlights at once")
            bubble.pressMoved(to: window.convertPoint(toScreen: outside))
            seen.append(bubble.highlighted)
            return [try Self.mouse(.leftMouseUp, at: outside, in: window)]
        }
        #expect(seen.count == 3 && seen[2] == nil, "the highlight stayed outside the editor: \(seen)")
    }

    @Test func aReleaseOnTheButtonOrOutsideKeepsTheEditorOpen() throws {
        let (sidebar, id, window, header, log) = try Self.fixture()
        defer { sidebar.list.groupEditor.hide(); window.close() }
        let more = header.moreButton
        let onButton = more.convert(NSPoint(x: more.bounds.midX, y: more.bounds.midY), to: nil)
        try Self.press(header, in: window) { _ in [try Self.mouse(.leftMouseUp, at: onButton, in: window)] }
        #expect(sidebar.list.groupEditor.shownGroup == id, "a plain click on the ⋮ no longer opens the editor")
        #expect(log.items.isEmpty, "a release on the button ran \(log.items)")
    }

    @Test func aReleaseOnAColorDotPicksItAndStaysOpen() throws {
        let (sidebar, id, window, header, log) = try Self.fixture()
        defer { sidebar.list.groupEditor.hide(); window.close() }
        try Self.press(header, in: window) { bubble in
            let blue = try #require(bubble.swatches.first { $0.color == .blue })
            let point = try Self.point(of: blue, in: window)
            return [try Self.mouse(.leftMouseDragged, at: point, in: window), try Self.mouse(.leftMouseUp, at: point, in: window)]
        }
        #expect(log.intents.contains { if case .setGroupColor(id, .palette(.blue)) = $0 { true } else { false } }, "\(log.intents)")
        #expect(sidebar.list.groupEditor.shownGroup == id, "a color pick closed the editor")
    }

    @Test func aPressOpenLeavesTheNameAloneUntilTyping() throws {
        let (sidebar, _, window, header, log) = try Self.fixture()
        defer { sidebar.list.groupEditor.hide(); window.close() }
        try Self.press(header, in: window) { _ in [] }
        let bubble = try #require(sidebar.list.groupEditor.bubble)
        #expect(bubble.nameField.currentEditor() == nil, "the drag-open put the keys in the name field")
        // Typing moves into the name, the character replacing it.
        bubble.keyDown(with: try Self.key("Z", code: 6))
        let editor = try #require(bubble.nameField.currentEditor(), "typing did not reach the name")
        #expect(editor.string == "Z")
        // Escape puts the name back and closes; nothing is renamed.
        bubble.keyDown(with: try Self.key("\u{1b}", code: 53))
        #expect(sidebar.list.groupEditor.shownGroup == nil)
        #expect(!log.intents.contains { if case .renameGroup = $0 { true } else { false } }, "Escape renamed: \(log.intents)")
        #expect(bubble.nameField.stringValue == "Group 1")
    }

    @Test func returnAndClickingAwayCommitAndAnEmptyNameReverts() throws {
        let (sidebar, id, window, header, log) = try Self.fixture()
        defer { sidebar.list.groupEditor.hide(); window.close() }
        try Self.press(header, in: window) { _ in [] }
        let bubble = try #require(sidebar.list.groupEditor.bubble)
        bubble.focusName()
        bubble.nameField.currentEditor()?.string = ""
        bubble.dismiss()
        #expect(!log.intents.contains { if case .renameGroup = $0 { true } else { false } }, "an empty name was committed")

        sidebar.list.groupEditor.hide()
        try Self.press(header, in: window) { _ in [] }
        let again = try #require(sidebar.list.groupEditor.bubble)
        again.focusName()
        again.nameField.currentEditor()?.string = "Renamed"
        // Clicking away closes the editor (it resigns key), which commits.
        again.dismiss()
        #expect(log.intents.contains { if case .renameGroup(id, "Renamed") = $0 { true } else { false } }, "\(log.intents)")
    }

    @Test func theArrowKeysWalkTheRowsAndReturnRunsOne() throws {
        let (sidebar, _, window, header, log) = try Self.fixture()
        defer { sidebar.list.groupEditor.hide(); window.close() }
        try Self.press(header, in: window) { _ in [] }
        let bubble = try #require(sidebar.list.groupEditor.bubble)
        let down = try Self.key(String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), code: 125)
        bubble.keyDown(with: down)
        bubble.keyDown(with: down)
        #expect(bubble.rows[1].isHighlighted)
        bubble.keyDown(with: try Self.key("\r", code: 36))
        #expect(log.items == [bubble.rows[1].item.id])
    }

    /// Spam open and close on a shown window: every open is at full size and opacity in its
    /// first frame (no entry motion), a close fades, and a reopen during that fade cuts it.
    @Test(.enabled("needs an awake display and animations on") { await GUIAnimationTestSupport.animatesHere() })
    func spamOpenAndCloseNeverStacksOrFlashes() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let parent = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.orderFrontRegardless()
        defer { parent.close() }
        let panel = SidebarGroupEditorPanel()
        let (sidebar, ids) = try GroupPaletteDefaultTests.sidebar([.red])
        let group = try #require(sidebar.list.groups[ids[0]])
        panel.configure(group, items: SidebarGroupEditing.standardItems())
        let anchor = PopupAnchor(rect: CGRect(x: 300, y: 500, width: 20, height: 20), edge: .trailing)
        panel.contentView?.wantsLayer = true
        let layer = try #require(panel.contentView?.layer)
        for round in 0..<20 {
            panel.present(at: anchor, parent: parent, focusesName: false)
            #expect(panel.alphaValue == 1 && layer.opacity == 1, "round \(round): the open is not at full opacity at once")
            #expect(layer.animation(forKey: "opacity") == nil && layer.animation(forKey: "sublayerTransform") == nil,
                    "round \(round): the open animates in")
            #expect(parent.childWindows?.filter { $0 === panel }.count == 1, "round \(round): the panel is stacked")
            panel.dismiss()
            #expect(!panel.isPresented)
            #expect(layer.animation(forKey: "opacity") != nil || !panel.isVisible, "round \(round): the close does not fade")
        }
        panel.present(at: anchor, parent: parent, focusesName: false)
        #expect(panel.isVisible && layer.opacity == 1 && layer.animation(forKey: "opacity") == nil, "the last open was left faded out")
        panel.dismiss()
    }

    /// Reduce Motion: the close ends in the frame it starts.
    @Test func reduceMotionClosesAtOnce() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let (sidebar, _, window, header, _) = try Self.fixture()
        defer { window.close() }
        try Self.press(header, in: window) { _ in [] }
        let bubble = try #require(sidebar.list.groupEditor.bubble)
        bubble.dismiss()
        #expect(bubble.contentView?.layer?.animation(forKey: "opacity") == nil)
        #expect(bubble.contentView?.layer?.animation(forKey: "sublayerTransform") == nil)
    }

    /// The workspace row's ⋮ shares the press: its menu opens inside the button's mouse-down,
    /// where the native menu tracks the same press (drag and release choose).
    @Test func theWorkspaceRowMoreButtonOpensItsMenuAtMouseDown() throws {
        let (sidebar, window, _, second, _, _) = try SidebarRowMenuNoFocusTests.sidebar()
        defer { window.close() }
        var presented = 0
        sidebar.list.menuPresenter = { _, _, _ in presented += 1 }
        let row = try #require(sidebar.list.rowViews[.workspace(second)] as? WorkspaceRowView)
        row.isHovered = true
        row.layoutSubtreeIfNeeded()
        let more = row.moreButton
        more.mouseDown(with: try Self.mouse(.leftMouseDown, at: more.convert(NSPoint(x: more.bounds.midX, y: more.bounds.midY), to: nil),
                                            in: window))
        #expect(presented == 1, "the row menu did not open at mouse-down")
    }
}

private extension NSView {
    /// The sidebar list this view is in.
    var enclosingList: SidebarListView? {
        var view = superview
        while let current = view {
            if let list = current as? SidebarListView { return list }
            view = current.superview
        }
        return nil
    }
}

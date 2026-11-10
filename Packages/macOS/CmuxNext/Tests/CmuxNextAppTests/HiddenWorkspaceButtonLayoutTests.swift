import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// WORKSPACE SWITCH 800: a switch to a workspace that shows a web page changes the key window (the page's Chromium
/// child window has the key; a sidebar click gives it to the main window, then the new page takes it back). At each key
/// window change AppKit sends `setNeedsLayout: true` to every button of the window, the buttons of the hidden (kept)
/// workspaces too (`-[NSControl _windowChangedKeyState]`, `-[NSButtonCell _redrawDueToWindowChangedKeyStateInView:]`,
/// `-[NSButtonCell invalidateBezelConfigurationForDisplayOrLayout:]`), and the next layout pass ran the cell layout of
/// each of them: 12.4 ms per switch with 32 kept workspaces (aws-m4pro-7, macOS 26.7, build 9db563c81bd9:
/// `TitlebarBandButton.layout` 9.5 ms, `OverflowButton` 2.1 ms, `ChromeIconButton` 0.8 ms), and the commit of a page
/// workspace switch was 12 ms later with 32 kept workspaces than with 4 (29.0 against 17.0 ms p50).
///
/// The rule (CLAUDE.md, "hidden workspaces do no view work until shown, then one layout"): a button that is hidden, or
/// under a hidden view, does no layout; it lays out one time when it shows. The tests send the mark AppKit sends: a test
/// process has no key window to change.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct HiddenWorkspaceButtonLayoutTests {
    /// A chrome button that counts its layouts.
    final class CountingButton: ClickableButton {
        var layouts = 0

        override func layout() {
            layouts += 1
            super.layout()
        }
    }

    /// The workspaces each size shows before the count, so that many stay mounted and hidden.
    static let kept = 8

    /// Every chrome button under `root`.
    static func buttons(under root: NSView) -> [ClickableButton] {
        var result: [ClickableButton] = []
        var stack = [root]
        while let view = stack.popLast() {
            if let button = view as? ClickableButton { result.append(button) }
            stack.append(contentsOf: view.subviews)
        }
        return result
    }

    /// `-[NSView layout]` calls of the view classes named `classes`, since launch.
    static func layouts(of classes: Set<String>) -> Int {
        LayoutPassGuard.shared.passesByClass.reduce(0) { $0 + (classes.contains($1.viewClass) ? $1.passes : 0) }
    }

    /// A button under a hidden view: two key window changes lay it out 0 times; it lays out one time when its container
    /// shows. A button that shows lays out at each mark, as before.
    @Test
    func aHiddenButtonLaysOutOneTimeWhenItShows() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try #require(window.contentView)
        let workspace = NSView(frame: content.bounds)
        let button = CountingButton(frame: NSRect(x: 10, y: 10, width: 28, height: 28))
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        workspace.addSubview(button)
        content.addSubview(workspace)
        content.layoutSubtreeIfNeeded()

        let shown = button.layouts
        button.needsLayout = true
        content.layoutSubtreeIfNeeded()
        #expect(button.layouts == shown + 1, "a button that shows lays out when it is marked: \(button.layouts - shown) layouts")

        workspace.isHidden = true
        content.layoutSubtreeIfNeeded()
        let hidden = button.layouts
        for _ in 0..<2 {
            button.needsLayout = true
            content.layoutSubtreeIfNeeded()
        }
        #expect(button.layouts == hidden, "a hidden button laid out \(button.layouts - hidden) times for 2 key window changes")

        workspace.isHidden = false
        content.layoutSubtreeIfNeeded()
        #expect(button.layouts == hidden + 1, "the button laid out \(button.layouts - hidden) times when its workspace showed, not 1 time")
    }

    /// A whole window of a session of `size` with ``kept`` more workspaces shown one after the other (each stays mounted,
    /// hidden): one key window change lays out only the buttons that show. The count does not grow with the kept
    /// workspaces or with the session.
    @Test(arguments: SessionFixtureSize.arms)
    func aKeyWindowChangeLaysOutNoButtonOfAKeptWorkspace(size: SessionFixtureSize) async throws {
        try await LargeSessionWindowFixture.withController(size) { store, controller in
            LayoutPassGuard.shared.install()
            let root = try #require(controller.window?.contentView)
            for number in 1...Self.kept {
                let key = WorkspaceKey(rawValue: LargeSessionWindowFixture.key(number))
                let id = try #require(store.workspaces.first { $0.key == key }, "fixture: no workspace \(number)").id
                controller.services.windows.show(workspaceID: id, in: controller.state, from: .thisWindow)
                await LargeSessionWindowFixture.drainMain()
                root.layoutSubtreeIfNeeded()
            }
            await LargeSessionWindowFixture.drainMain()
            root.layoutSubtreeIfNeeded()
            try #require(controller.parked.count >= Self.kept, "fixture: \(controller.parked.count) kept workspaces, not \(Self.kept)")

            let buttons = Self.buttons(under: root)
            let hidden = buttons.filter(\.isHiddenOrHasHiddenAncestor).count
            try #require(hidden > 0, "fixture: no button in the \(controller.parked.count) kept workspaces")
            let classes = Set(buttons.map { String(describing: type(of: $0)) })

            let before = Self.layouts(of: classes)
            for button in buttons { button.needsLayout = true }
            root.layoutSubtreeIfNeeded()
            let laidOut = Self.layouts(of: classes) - before
            let shown = buttons.count - hidden
            print("HIDDEN-BUTTON-LAYOUT size=\(size.rawValue) kept=\(controller.parked.count) buttons=\(buttons.count) hidden=\(hidden) shown=\(shown) laid_out=\(laidOut)")
            #expect(laidOut <= shown, "one key window change laid out \(laidOut) buttons; \(shown) show and \(hidden) are in the \(controller.parked.count) kept workspaces")
        }
    }
}

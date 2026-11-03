import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// ``WindowKeyStateWalk``: AppKit's key-state walk of a window's content runs only when the window's family (the window,
/// its child windows and sheets) gains or loses the keyboard, once per turn.
@MainActor
@Suite(.closesItsWindows) struct WindowKeyStateWalkGateTests {
    @MainActor
    final class Keyboard {
        var key: NSWindow?
        var active = true
        var pending: [@MainActor () -> Void] = []

        var environment: WindowKeyEnvironment {
            WindowKeyEnvironment(keyWindow: { [unowned self] in self.key }, isAppActive: { [unowned self] in self.active },
                                 nextTurn: { [unowned self] check in self.pending.append(check) })
        }

        /// Runs the checks the gate left for the next turn.
        func nextTurn() {
            let checks = pending
            pending.removeAll()
            for check in checks { check() }
        }
    }

    private static func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func theContentWalksOnlyWhenTheFamilyGainsOrLosesTheKeyboard() {
        let keyboard = Keyboard()
        let parent = Self.window(), page = Self.window(), other = Self.window()
        defer { [parent, page, other].forEach { $0.close() } }
        parent.addChildWindow(page, ordered: .above)
        let content = FamilyKeyStateView(frame: parent.contentView?.bounds ?? .zero)
        parent.contentView = content
        content.keyStateWalk = WindowKeyStateWalk(environment: keyboard.environment)
        var walked = 0
        @MainActor func notice(key: NSWindow?) {
            keyboard.key = key
            content.keyStateWalk.keyStateChanged(of: content) { walked += 1 }
        }

        notice(key: parent)
        keyboard.nextTurn()
        #expect(walked == 1, "the first notice brings the content to the family's state")
        // Cmd-T's New Tab page: the keys move to the window's own page window, and back on Cmd-W.
        notice(key: page)
        keyboard.nextTurn()
        notice(key: parent)
        keyboard.nextTurn()
        #expect(walked == 1, "a key move inside the family walked the content")
        // A resign and a become in one turn (no key window in between) are one check.
        notice(key: nil)
        notice(key: other)
        #expect(keyboard.pending.count == 1)
        keyboard.nextTurn()
        #expect(walked == 2, "the keyboard left the family: the content walks once")
        notice(key: parent)
        keyboard.nextTurn()
        #expect(walked == 3, "the keyboard came back to the family: the content walks once")
        keyboard.active = false
        notice(key: nil)
        keyboard.nextTurn()
        #expect(walked == 4, "the app resigned: the content walks once")
    }
}

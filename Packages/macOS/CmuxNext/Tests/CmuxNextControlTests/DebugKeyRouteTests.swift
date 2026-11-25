#if DEBUG
import CmuxNextControl
import Testing

/// `debug.key` with no `target` goes where a person's key goes (``DebugKeyRoute``). On a fleet Mac
/// (esc1 capture, 2026-11-20) the composer's + menu was open, so the Chromium page window was key, and
/// a real Escape closed the menu. `debug.key {"key": "escape"}` went to the shell window, which was not
/// key, and the menu stayed open, so a capture tour's "close the menu" step did nothing. A capture slot
/// that never activates has no key window at all (esc2 at aeb12e07: the menu stayed open again): there a
/// person's key would go to the chat that has the keyboard, the focused pane's Chromium page window.
@Suite struct DebugKeyRouteTests {
    private final class Window {}
    private let shell = Window(), page = Window(), otherShell = Window()

    @Test func keyFollowsTheShellsKeyChildWindow() {
        let route = DebugKeyRoute(shell: shell, keyWindow: page, keyWindowParent: shell)
        #expect(route.window(target: nil) === page)
    }

    @Test func explicitShellTargetKeepsTheShellWindow() {
        let route = DebugKeyRoute(shell: shell, keyWindow: page, keyWindowParent: shell)
        #expect(route.window(target: "shell") === shell)
    }

    @Test(arguments: [false, true])
    func keyStaysOnTheShellWhenNoChildOfItIsKey(shellIsKey: Bool) {
        let route = DebugKeyRoute(shell: shell, keyWindow: shellIsKey ? shell : nil, keyWindowParent: nil)
        #expect(route.window(target: nil) === shell)
    }

    @Test func noKeyWindowGoesToTheFocusedChatsPage() {
        let route = DebugKeyRoute(shell: shell, keyWindow: nil, keyWindowParent: nil, focusedPage: page)
        #expect(route.window(target: nil) === page)
        #expect(route.window(target: "shell") === shell)
    }

    @Test func aKeyShellKeepsTheShellOverTheFocusedPage() {
        let route = DebugKeyRoute(shell: shell, keyWindow: shell, keyWindowParent: nil, focusedPage: page)
        #expect(route.window(target: nil) === shell)
    }

    @Test func anotherShellsChildWindowIsNotFollowed() {
        let route = DebugKeyRoute(shell: shell, keyWindow: page, keyWindowParent: otherShell)
        #expect(route.window(target: nil) === shell)
    }
}
#endif

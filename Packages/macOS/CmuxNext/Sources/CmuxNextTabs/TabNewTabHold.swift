import AppKit

/// Press-and-hold on + opens the new tab menu (`TabStripView.showNewTabMenu`), as a long press on a
/// back button opens history. The strip holds one: `start` on a press on +, `end` on mouse-up.
@MainActor final class TabNewTabHold {
    private weak var strip: TabStripView?
    private var task: Task<Void, Never>?
    private var openedMenu = false

    init(strip: TabStripView) { self.strip = strip }

    /// Holding + opens the new tab menu, as a long press on a back button opens history.
    func start() {
        task?.cancel()
        openedMenu = false
        guard let sleep = strip?.groups.sleep else { return }
        task = Task { [weak self] in
            do { try await sleep(.milliseconds(450)) } catch { return } // wakeup-allow: the one 450 ms press-and-hold delay; end() cancels it
            guard let self, let strip = self.strip, !Task.isCancelled, strip.pressedNewTab else { return }
            self.openedMenu = true
            strip.newTabButton.isPressed = false
            strip.pressedNewTab = false
            strip.showNewTabMenu()
        }
    }

    /// Mouse-up: ends the hold. Returns whether the hold already showed the menu (the press must not
    /// also open a tab).
    func end() -> Bool {
        task?.cancel()
        task = nil
        defer { openedMenu = false }
        return openedMenu
    }
}

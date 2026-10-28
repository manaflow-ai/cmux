import AppKit
import CmuxNextWakeups

/// Press-and-hold on + opens the new tab menu (`TabStripView.showNewTabMenu`), as a long press on a
/// back button opens history. The strip holds one: `start` on a press on +, `end` on mouse-up. The hold is a
/// `userBlocking` deadline on the app's placer: the person waits on it.
@MainActor final class TabNewTabHold {
    private weak var strip: TabStripView?
    private let hold: MainDeadline
    private var openedMenu = false

    init(strip: TabStripView) {
        self.strip = strip
        hold = MainDeadline(owner: "TabStrip.newTabHold", workClass: .userBlocking, scheduler: strip.deadlines)
    }

    /// Holding + opens the new tab menu, as a long press on a back button opens history.
    func start() {
        openedMenu = false
        hold.schedule(after: .milliseconds(450)) { [weak self] in
            guard let self, let strip, strip.pressedNewTab else { return }
            openedMenu = true
            strip.newTabButton.isPressed = false
            strip.pressedNewTab = false
            strip.showNewTabMenu()
        }
    }

    /// Mouse-up: ends the hold. Returns whether the hold already showed the menu (the press must not
    /// also open a tab).
    func end() -> Bool {
        hold.cancel()
        defer { openedMenu = false }
        return openedMenu
    }
}

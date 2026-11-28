import AppKit
import CmuxNextDaemon
import CmuxNextTabs

// Anchors at a group chip in a tab strip: the icon picker of a tab group or
// screen group opens beside the chip it draws on, like the group editor.
extension IconPickerService {
    /// An anchor at tab group `id`'s chip in the strip of the pane that holds
    /// it (on whichever machine owns it), else the top middle of the active window.
    func anchor(tabGroup id: String) -> Anchor? {
        let strip = services.flatMap { services in
            GroupOwnership.pane(holdingTabGroup: CmuxNextDaemon.TabGroupID(rawValue: id), machines: services.machines)
                .flatMap { services.paneController(for: $0.pane)?.view.stripView }
        }
        return chipAnchor(CmuxNextTabs.TabGroupID(id), in: strip) ?? activeWindowAnchor()
    }

    /// An anchor at screen group `id`'s chip in the screen bar of the window
    /// showing its workspace, else the top middle of the active window.
    func anchor(screenGroup id: String) -> Anchor? {
        let content = services?.windows.controllers.lazy.compactMap(\.content).first {
            $0.workspace.screenGroups.contains { $0.id.rawValue == id }
        }
        return chipAnchor(CmuxNextTabs.TabGroupID(id), in: content?.screenBar.view) ?? activeWindowAnchor()
    }

    /// The chip's frame in its window's content view; nil when the strip is
    /// not in a window or draws no chip for `group` (a hidden bar).
    private func chipAnchor(_ group: CmuxNextTabs.TabGroupID, in strip: TabStripView?) -> Anchor? {
        guard let strip, let screen = group.chipFrameOnScreen(in: strip), let window = strip.window,
              let content = window.contentView else { return nil }
        return Anchor(view: content, rect: content.convert(window.convertFromScreen(screen), from: nil))
    }
}

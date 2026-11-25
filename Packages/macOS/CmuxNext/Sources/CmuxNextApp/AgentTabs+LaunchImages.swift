import AppKit
import CmuxNextTabs

extension AgentTabStore {
    /// The agent views on screen but `isIncognito`'s, by saved-page slot, each with its page once painted: saved for the next launch (`AgentPaneLaunchImages`).
    func shownPageImages(but isIncognito: (AgentTabKey) -> Bool) async -> [String: NSImage?] {
        var images: [String: NSImage?] = [:]
        for (key, view) in views where view.window?.isVisible == true && !view.isHiddenOrHasHiddenAncestor {
            if case let scoped = resolvedKey(key), !isIncognito(scoped) { images[launchImages.slot(scoped.key, machine: scoped.machine)] = .some(view.model.hasPainted ? await view.pageImage() : nil) }
        }
        return images
    }
}

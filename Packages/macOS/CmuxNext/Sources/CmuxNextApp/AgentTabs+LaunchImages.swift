import AppKit

extension AgentTabStore {
    /// The pages of the agent views on screen that have painted, by tab
    /// key: saved at quit for the next launch (`AgentPaneLaunchImages`).
    func shownPageImages() async -> [(machine: String, key: String, image: NSImage)] {
        var images: [(machine: String, key: String, image: NSImage)] = []
        for (key, view) in views where view.model.hasPainted && view.window?.isVisible == true && !view.isHiddenOrHasHiddenAncestor {
            if let image = await view.pageImage() { let scoped = resolvedKey(key); images.append((scoped.machine, scoped.key, image)) }
        }
        return images
    }
}

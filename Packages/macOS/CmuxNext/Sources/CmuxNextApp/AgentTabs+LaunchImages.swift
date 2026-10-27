import AppKit

extension AgentTabStore {
    /// The pages of the agent views on screen that have painted, by tab
    /// key: saved at quit for the next launch (`AgentPaneLaunchImages`).
    func shownPageImages() async -> [String: NSImage] {
        // memory: fixed a local of one quit's save: one picture per agent view on screen, handed to `AgentPaneLaunchImages.save`
        var images: [String: NSImage] = [:]
        for (key, view) in views where view.model.hasPainted && view.window?.isVisible == true && !view.isHiddenOrHasHiddenAncestor {
            if let image = await view.pageImage() { images[key] = image }
        }
        return images
    }
}

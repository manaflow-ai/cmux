import AppKit
import CmuxNextWakeups

// Chrome's address bar menu items and full-URL display (`OmnibarDisplay`),
// and site icons in suggestion rows.
extension AddressBarView {
    /// Follows `suggestionEngine.display.showsFullURLs` into the state machine, now and at the
    /// next frame after a change. A new engine starts it again (`suggestionEngine` didSet).
    func followDisplay() {
        displayWatch?.cancel()
        let display = suggestionEngine.display
        // node-free: an app-wide setting; the bar sits in a tab's chrome, a popup's toolbar or the Markdown bar, with no tab node
        let watch = FrameObservation(owner: "browser.omnibar.fullURLs", delivery: .visible(nil), on: mainWork) { [weak display] in
            display?.showsFullURLs ?? false
        } onChange: { [weak self] full in
            self?.controller.send(.showFullURLsChanged(full))
        }
        displayWatch = watch
        controller.send(.showFullURLsChanged(watch.value))
    }

    /// The bar's own items at the end of the field's context menu.
    func omnibarMenuItems() -> [NSMenuItem] {
        let display = suggestionEngine.display
        var items: [NSMenuItem] = []
        if display.setShowsFullURLs != nil {
            let item = NSMenuItem(title: Strings.alwaysShowFullURLs, action: #selector(toggleFullURLs(_:)), keyEquivalent: "")
            item.target = self
            item.state = display.showsFullURLs ? .on : .off
            items.append(item)
        }
        if display.manageSearchEngines != nil {
            let item = NSMenuItem(title: Strings.manageSearchEngines, action: #selector(manageSearchEngines(_:)), keyEquivalent: "")
            item.target = self
            items.append(item)
        }
        return items
    }

    @objc func toggleFullURLs(_ sender: Any?) {
        let display = suggestionEngine.display
        display.setShowsFullURLs?(!display.showsFullURLs)
    }

    @objc func manageSearchEngines(_ sender: Any?) {
        suggestionEngine.display.manageSearchEngines?()
    }
}

import AppKit
import Observation

// Chrome's address bar menu items and full-URL display (`OmnibarDisplay`),
// and site icons in suggestion rows.
extension AddressBarView {
    /// Follows `suggestionEngine.display.showsFullURLs` into the state machine,
    /// now and on every change. A new engine starts it again (`suggestionEngine` didSet).
    func followDisplay() {
        let display = suggestionEngine.display
        let full = withObservationTracking { display.showsFullURLs } onChange: { [weak self, weak display] in
            // task-owner: one hop per change; ends at once (the view or engine may be gone).
            Task { @MainActor [weak self, weak display] in
                guard let self, let display, display === self.suggestionEngine.display else { return }
                self.followDisplay()
            }
        }
        controller.send(.showFullURLsChanged(full))
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

import AppKit

/// Back/forward menus: right-click or long-press the Back or
/// Forward button for the tab's entries, nearest first (plans/cmux-next/
/// history.md 4.1). Only for tabs whose engine lists its entries
/// (`BrowserBackForwardListing`).
extension BrowserChromeView {
    static let backForwardMenuLimit = 16

    /// Targets the Back and Forward buttons at this view and gives them
    /// their entry menus.
    func installBackForwardMenus() {
        backButton.target = self
        forwardButton.target = self
        backButton.menuProvider = { [weak self] in self?.backForwardMenu(forward: false) }
        forwardButton.menuProvider = { [weak self] in self?.backForwardMenu(forward: true) }
    }

    func backForwardMenu(forward: Bool) -> NSMenu? {
        guard let listing = tab as? any BrowserBackForwardListing, let list = listing.navigationList() else { return nil }
        let entries = (forward ? list.forward : list.back).prefix(Self.backForwardMenuLimit)
        guard !entries.isEmpty else { return nil }
        let menu = NSMenu()
        for (offset, entry) in entries {
            let title = entry.title.flatMap { $0.isEmpty ? nil : $0 } ?? entry.url?.absoluteString ?? ""
            let item = NSMenuItem(title: title, action: #selector(goToBackForwardEntry(_:)), keyEquivalent: "")
            item.target = self
            item.tag = offset
            item.toolTip = entry.url?.absoluteString
            menu.addItem(item)
        }
        return menu
    }

    @objc func goToBackForwardEntry(_ sender: NSMenuItem) {
        (tab as? any BrowserBackForwardListing)?.goToEntry(offset: sender.tag)
    }
}

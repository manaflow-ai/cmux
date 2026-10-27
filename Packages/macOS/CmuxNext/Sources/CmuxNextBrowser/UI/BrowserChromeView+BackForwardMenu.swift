import AppKit
import CmuxNextDesign

/// Back/forward menus: right-click or long-press the Back or
/// Forward button for the tab's entries, nearest first (plans/cmux-next/
/// history.md 4.1). Only for tabs whose engine lists its entries
/// (`BrowserBackForwardListing`). Reload has its own menu (`BrowserReloadMenu`).
/// Both are standard macOS menus in the toolbar's light or dark look (`NSMenu.themeRows(in:)`).
extension BrowserChromeView {
    static let backForwardMenuLimit = 16

    /// Targets the Back and Forward buttons at this view and gives them
    /// their entry menus.
    func installBackForwardMenus() {
        backButton.target = self
        forwardButton.target = self
        backButton.menuProvider = { [weak self] in self?.backForwardMenu(forward: false) }
        forwardButton.menuProvider = { [weak self] in self?.backForwardMenu(forward: true) }
        reloadButton.menuProvider = { [weak self] in self.map { BrowserReloadMenu.make(for: $0.tab, in: $0.themeScope.fullStrength) } }
    }

    func backForwardMenu(forward: Bool) -> NSMenu? {
        guard let listing = tab as? any BrowserBackForwardListing, let list = listing.navigationList() else { return nil }
        return backForwardMenu(Array((forward ? list.forward : list.back).prefix(Self.backForwardMenuLimit)))
    }

    /// One row per entry (its title, else its address) with a page glyph, going that many entries
    /// away; nil without entries.
    func backForwardMenu(_ entries: [(offset: Int, entry: BrowserNavigationEntry)]) -> NSMenu? {
        guard !entries.isEmpty else { return nil }
        let menu = NSMenu()
        for (offset, entry) in entries {
            let title = entry.title.flatMap { $0.isEmpty ? nil : $0 } ?? entry.url?.absoluteString ?? ""
            let item = NSMenuItem(title: title, action: #selector(goToBackForwardEntry(_:)), keyEquivalent: "")
            item.target = self
            item.tag = offset
            item.toolTip = entry.url?.absoluteString
            item.image = NSImage.menuSymbol("globe")
            menu.addItem(item)
        }
        return menu.themeRows(in: themeScope.fullStrength)
    }

    @objc func goToBackForwardEntry(_ sender: NSMenuItem) {
        (tab as? any BrowserBackForwardListing)?.goToEntry(offset: sender.tag)
    }
}

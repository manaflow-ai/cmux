import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// Back/forward menus: right-click or long-press the Back or
/// Forward button for the tab's entries, nearest first (plans/cmux-next/
/// history.md 4.1). Only for tabs whose engine lists its entries
/// (`BrowserBackForwardListing`). Reload has its own menu (`BrowserReloadMenu`).
/// Both are standard macOS menus in the toolbar's light or dark look (`NSMenu.themeRows(in:)`).
extension BrowserChromeView {
    static let backForwardMenuLimit = 16

    /// Targets the Back and Forward buttons at this view and gives them
    /// their entry menus, on right-click and on a long press.
    func installBackForwardMenus() {
        backButton.target = self
        forwardButton.target = self
        backButton.menuProvider = { [weak self] in self?.backForwardMenu(forward: false) }
        forwardButton.menuProvider = { [weak self] in self?.backForwardMenu(forward: true) }
        reloadButton.menuProvider = { [weak self] in self.map { BrowserReloadMenu.make(for: $0.tab, in: $0.themeScope.fullStrength) } }
        // A long press's menu is visible work behind the person's input, on the main thread's one wake-up
        // queue (`mainWork.wakeUps`), as the titlebar's Back and Forward.
        let deadlines = MainDeadlineScheduler(work: mainWork)
        backButton.longPressDeadline = MainDeadline(owner: "browser.chrome.backLongPress", workClass: .visible, scheduler: deadlines)
        forwardButton.longPressDeadline = MainDeadline(owner: "browser.chrome.forwardLongPress", workClass: .visible, scheduler: deadlines)
        reloadButton.longPressDeadline = MainDeadline(owner: "browser.chrome.reloadLongPress", workClass: .visible, scheduler: deadlines)
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

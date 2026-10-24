#if DEBUG
public import AppKit
public import CmuxNextCompat

/// Debug menu > Main-Thread Blocking (N): how many call sites blocked the main thread since launch
/// (the main-thread blocking detector, plans/cmux-next/threading-model.md), one row per site with
/// its count, and Reset Counts. Debug builds only: a Nightly (to come) will send its sites to the opt-in hang
/// reports and show nothing.
///
/// It is the delegate of the Debug menu that holds its item (``attach(to:)``), so the count is read
/// when that menu opens and the rows when the submenu opens; nothing runs while they are closed.
///
/// ```swift
/// let blocking = BlockingCallsMenu(detector: services.blocking)
/// blocking.attach(to: debugMenu)
/// ```
public final class BlockingCallsMenu: NSObject, NSMenuDelegate {
    private let detector: BlockingDetector
    private let item: NSMenuItem
    private let submenu: NSMenu

    /// Makes the menu over the composition root's detector handle.
    public init(detector: BlockingDetector) {
        self.detector = detector
        item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        submenu = NSMenu(title: "")
        super.init()
        submenu.delegate = self
        item.submenu = submenu
        item.representedObject = self  // the menu keeps this object alive
        item.title = Self.title(detector.sites.count)
        submenu.title = item.title
    }

    /// Adds the item at the end of `debugMenu` (after a separator) and becomes its delegate, which
    /// `debugMenu` must not have yet: the Debug menu is built by `MainMenu` with no delegate.
    public func attach(to debugMenu: NSMenu) {
        assert(debugMenu.delegate == nil, "the Debug menu has another delegate")
        debugMenu.addItem(.separator())
        debugMenu.addItem(item)
        debugMenu.delegate = self
    }

    /// Refreshes the count (the Debug menu) or the site rows (the submenu) before a menu opens.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        let sites = detector.sites
        item.title = Self.title(sites.count)
        guard menu === submenu else { return }
        menu.removeAllItems()
        for site in sites {
            // Kind, code location and count are diagnostic tokens, not prose: not localized.
            let row = NSMenuItem(title: "\(site.kind.rawValue)  \(site.location)  ×\(site.count)", action: nil, keyEquivalent: "")
            row.isEnabled = false
            menu.addItem(row)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let reset = NSMenuItem(title: String(localized: "debug.blockingCalls.reset", defaultValue: "Reset Counts", bundle: .module),
                               action: #selector(resetCounts(_:)), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
    }

    @objc private func resetCounts(_ sender: NSMenuItem) {
        detector.resetCounts()
    }

    private static func title(_ count: Int) -> String {
        String(localized: "debug.blockingCalls", defaultValue: "Main-Thread Blocking (\(count))", bundle: .module)
    }
}
#endif

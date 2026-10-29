#if DEBUG
public import AppKit
public import CmuxNextCompat

/// Debug menu > Main-Thread Blocking (N): how many call sites blocked the main thread since launch
/// (the main-thread blocking detector, plans/cmux-next/threading-model.md), one row per site with
/// its count, and Reset Counts. Debug builds only: a Nightly logs its sites (``BlockingLogSink``) and shows
/// nothing.
///
/// A site nobody has looked at yet is a badge on the item (the number of new sites since the submenu last
/// opened): Debug records instead of stopping at the call, so the badge and the
/// unified-log fault are what make a new site loud. Opening the submenu clears it.
///
/// It is the delegate of the Debug menu that holds its item (``attach(to:)``), so the count is read
/// when that menu opens and the rows when the submenu opens; nothing runs while they are closed.
/// Reset Counts is the registered action `debug.blockingCalls.reset` (scripts/cmux-next/check-menu-actions.py:
/// a menu row runs the action the palette runs), made by the caller's `resetItem` and shown as "Reset Counts".
///
/// ```swift
/// let blocking = BlockingCallsMenu(detector: services.blocking,
///                                  resetItem: { registry.makeMenuItem(for: "debug.blockingCalls.reset") })
/// blocking.attach(to: debugMenu)
/// ```
public final class BlockingCallsMenu: NSObject, NSMenuDelegate {
    private let detector: BlockingDetector
    private let item: NSMenuItem
    private let submenu: NSMenu
    private let resetItem: () -> NSMenuItem?
    /// How many sites the submenu showed when it last opened: the sites past it are new.
    private var seenSites = 0

    /// Makes the menu over the composition root's detector handle. `resetItem` makes the Reset Counts
    /// row (the registry's item for `debug.blockingCalls.reset`); nil leaves the row out.
    public init(detector: BlockingDetector, resetItem: @escaping () -> NSMenuItem?) {
        self.detector = detector
        self.resetItem = resetItem
        item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        submenu = NSMenu(title: "")
        super.init()
        submenu.delegate = self
        item.submenu = submenu
        item.representedObject = self  // the menu keeps this object alive
        item.title = Self.title(Self.mainSites(detector).count)
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
        let sites = Self.mainSites(detector)
        item.title = Self.title(sites.count)
        if menu === submenu { seenSites = sites.count }
        let unseen = sites.count - seenSites
        item.badge = unseen > 0 ? NSMenuItemBadge(count: unseen) : nil
        guard menu === submenu else { return }
        menu.removeAllItems()
        for site in sites {
            // Kind, code location and count are diagnostic tokens, not prose: not localized.
            let row = NSMenuItem(title: "\(site.kind.rawValue)  \(site.location)  ×\(site.count)", action: nil, keyEquivalent: "")
            row.isEnabled = false
            menu.addItem(row)
        }
        guard let reset = resetItem() else { return }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        // Inside this submenu the short title reads right; the palette shows the action's full title.
        reset.title = String(localized: "debug.blockingCalls.reset", defaultValue: "Reset Counts", bundle: .module)
        menu.addItem(reset)
    }

    /// The main-thread sites: the menu is the main thread's; pool sites are in `debug.blocking`.
    private static func mainSites(_ detector: BlockingDetector) -> [BlockingSite] {
        detector.sites.filter { $0.context == .main }
    }

    private static func title(_ count: Int) -> String {
        String(localized: "debug.blockingCalls", defaultValue: "Main-Thread Blocking (\(count))", bundle: .module)
    }
}
#endif

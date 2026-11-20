public import AppKit
import CmuxNextActions
import CmuxNextDesign

/// The menu bar item shown while the Chief can see this Mac's screen, visible from every app: it
/// says so and offers Look Now and Stop Sharing, the registered `chief.screenShare.look` and
/// `chief.screenShare.stop` rows (the same path as the palette and the CLI).
@MainActor
public final class ChiefScreenShareIndicator {
    /// The registry's row for an action (`ActionRegistry.makeMenuItem`); ``ChiefScreenShareActions`` sets it.
    var menuItem: (ActionID) -> NSMenuItem? = { _ in nil }
    private let showsInMenuBar: Bool
    private var item: NSStatusItem?
    /// Whether the indicator is up now (in tests too, where it never reaches the menu bar).
    public private(set) var isVisible = false

    /// - Parameter showsInMenuBar: False keeps the item out of the system menu bar (tests).
    public init(showsInMenuBar: Bool = true) {
        self.showsInMenuBar = showsInMenuBar
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        if visible, item == nil, showsInMenuBar {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let title = ChiefScreenShareStrings.indicatorTitle
            let image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: title)
            image?.isTemplate = true
            item.button?.image = image
            item.button?.themedToolTip = title
            item.button?.setAccessibilityIdentifier("cmux.chiefScreenShare.indicator")
            let menu = NSMenu()
            let heading = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            menu.addItem(.separator())
            for id in [ChiefScreenShareActions.lookID, ChiefScreenShareActions.stopID] {
                if let row = menuItem(id) { menu.addItem(row) }
            }
            item.menu = menu
            self.item = item
        } else if !visible, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }
}

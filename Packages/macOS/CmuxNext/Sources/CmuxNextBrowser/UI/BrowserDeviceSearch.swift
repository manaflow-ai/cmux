import AppKit
import CmuxNextDesign

/// The search field on top of the device menu's All Devices submenu: as you type, it hides the browse rows
/// (group headers, brand submenus, devices) and lists the devices whose brand and title hold every typed word,
/// newest first; an empty field shows the browse rows again. The field item keeps this object alive.
@MainActor
final class BrowserDeviceSearch: NSObject, NSSearchFieldDelegate {
    /// The tag of the rows a search adds (removed by the next search).
    private static let resultTag = 0x5EA4C4
    private let devices: [BrowserDeviceMenu.Device]
    private let addRow: @MainActor (BrowserDeviceMenu.Device, NSMenu) -> Void
    private weak var menu: NSMenu?

    /// - Parameters:
    ///   - devices: every built-in device, in result order (newest first).
    ///   - addRow: appends a device's row (title, checkmark, action) to a menu, as the browse rows are made.
    init(devices: [BrowserDeviceMenu.Device], addRow: @escaping @MainActor (BrowserDeviceMenu.Device, NSMenu) -> Void) {
        self.devices = devices
        self.addRow = addRow
    }

    /// The search of `menu` (an All Devices submenu), if it has one.
    static func of(_ menu: NSMenu) -> BrowserDeviceSearch? {
        menu.items.first?.representedObject as? BrowserDeviceSearch
    }

    /// The menu item holding the search field (the first item of All Devices).
    func fieldItem() -> NSMenuItem {
        let field = NSSearchField(frame: NSRect(x: 12, y: 4, width: 216, height: 22))
        field.focusRingType = .none
        field.placeholderString = BrowserDeviceMenu.Strings.search
        field.sendsSearchStringImmediately = true
        field.delegate = self
        field.setAccessibilityLabel(BrowserDeviceMenu.Strings.search)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        container.addSubview(field)
        let item = NSMenuItem()
        item.view = container
        item.representedObject = self
        return item
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField, let menu = field.enclosingMenuItem?.menu ?? menu else { return }
        apply(field.stringValue, in: menu)
    }

    /// Shows the devices matching `query` in `menu`, or the browse rows when `query` is blank.
    func apply(_ query: String, in menu: NSMenu) {
        self.menu = menu
        for item in menu.items.reversed() where item.tag == Self.resultTag {
            menu.removeItem(item)
        }
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        for item in menu.items.dropFirst() {
            item.isHidden = !words.isEmpty
        }
        // The browse rows show again, a checked device among them: the themed menu measures its
        // columns again, so its rows take the state column back while it is open.
        guard !words.isEmpty else { return menu.themeAddedRows() }
        let matches = devices.filter { device in
            let text = "\(device.brand) \(device.title)"
            return words.allSatisfy { text.localizedStandardContains($0) }
        }
        let before = menu.items.count
        if matches.isEmpty {
            let none = NSMenuItem(title: BrowserDeviceMenu.Strings.noMatch, action: nil, keyEquivalent: "")
            none.image = NSImage.menuSymbol("magnifyingglass")
            none.isEnabled = false
            menu.addItem(none)
        }
        for device in matches {
            addRow(device, menu)
        }
        for item in menu.items[before...] {
            item.tag = Self.resultTag
        }
        // Results added while a themed menu is open take its look.
        menu.themeAddedRows()
    }
}

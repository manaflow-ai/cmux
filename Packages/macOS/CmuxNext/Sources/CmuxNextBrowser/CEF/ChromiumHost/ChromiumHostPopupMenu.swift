import AppKit

// `<select>` popups drawn by cmux (plans/cmux-next/chrome-parity/p01-process.md, task 060). The
// Chromium Host is never the active app, so Chromium's own popup menu (`content::PopupMenuHelper`,
// content/browser/renderer_host/popup_menu_helper_mac.mm) would track in a process the person is not
// using. With the fork's popup handler (task 171) the host sends each popup as data, POPUP_MENU
// {token, items, bounds, font size, right aligned, selected}, and cmux shows it over the page view and
// answers the chosen index or -1. Chrome splits the same way: its browser process sends
// `RenderWidgetHostNSView.DisplayPopupMenu` to the view in the app shim, which runs the menu with
// `WebMenuRunner` (content/app_shim_remote_cocoa/web_menu_runner_mac.mm) and replies, and
// `PopupMenuRunner.Hide` cancels it (content/common/render_widget_host_ns_view.mojom).

/// One POPUP_MENU's popup: a page's `<select>` as data (cmux_cef_shim.h, CMUX_SHIM_POPUP_MENU).
nonisolated struct ChromiumHostPopupMenu: Equatable, Sendable, Decodable {
    /// One row (cef_cmux.h's cmux_popup_menu_item_t).
    nonisolated struct Item: Equatable, Sendable, Decodable {
        /// blink::mojom::MenuItem::Type.
        nonisolated enum Kind: Int, Sendable {
            case option = 0
            case checkable = 1
            /// An `<optgroup>` label: its options follow it.
            case group = 2
            case separator = 3
            case submenu = 4
        }

        var label: String
        var toolTip: String
        /// ``Kind``'s raw value; a kind this cmux does not know reads as a ``Kind/group`` label.
        var type: Int
        var enabled: Bool
        var checked: Bool
        /// The text runs right to left (its CSS direction).
        var rtl: Bool
        /// Its unicode-bidi overrides the text's direction.
        var directionOverride: Bool

        init(label: String, toolTip: String = "", kind: Kind = .option, enabled: Bool = true, checked: Bool = false,
             rtl: Bool = false, directionOverride: Bool = false) {
            self.label = label
            self.toolTip = toolTip
            type = kind.rawValue
            self.enabled = enabled
            self.checked = checked
            self.rtl = rtl
            self.directionOverride = directionOverride
        }

        var kind: Kind { Kind(rawValue: type) ?? .group }

        /// The page takes it as a choice: an enabled option. The fork refuses the others, as
        /// Chrome's menu never offers them.
        var isChoosable: Bool { enabled && (kind == .option || kind == .checkable) }
    }

    var x: Int32
    var y: Int32
    var width: Int32
    var height: Int32
    /// The items' size in points; 0 for the menu's own.
    var fontSize: Double
    /// The selected item's index, -1 for none: the menu puts it over the `<select>`.
    var selected: Int
    /// The `<select>` runs right to left: the menu's items align to the right.
    var rightAligned: Bool
    var items: [Item]

    init(bounds: CGRect, items: [Item], selected: Int = -1, fontSize: Double = 0, rightAligned: Bool = false) {
        x = Int32(bounds.minX)
        y = Int32(bounds.minY)
        width = Int32(bounds.width)
        height = Int32(bounds.height)
        self.items = items
        self.selected = selected
        self.fontSize = fontSize
        self.rightAligned = rightAligned
    }

    /// CMUX_SHIM_POPUP_MENU's s1; nil for JSON this cmux cannot read, which is answered -1 so the
    /// page's popup closes.
    init?(json: String) {
        guard let popup = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)) else { return nil }
        self = popup
    }

    /// The `<select>`'s rect in the page view's points, from its top left.
    var bounds: CGRect { CGRect(x: Int(x), y: Int(y), width: Int(width), height: Int(height)) }
}

/// One popup's menu over its `<select>` in a page view, built and tracked as Chrome's `WebMenuRunner`
/// does (content/app_shim_remote_cocoa/web_menu_runner_mac.mm): an `NSPopUpButtonCell` on the
/// items puts the selected one over the `<select>`'s rect, in the page's font size and alignment.
struct ChromiumHostPopupMenuRun {
    /// Records the chosen row (each row's target).
    final class Choice: NSObject {
        private(set) var index: Int?

        @objc func chose(_ sender: NSMenuItem) {
            index = sender.tag
        }
    }

    let menu: NSMenu
    let choice: Choice
    /// The `<select>`'s rect in `view`'s coordinates.
    let rect: CGRect
    let view: NSView
    let selected: Int
    let rightAligned: Bool

    init(_ popup: ChromiumHostPopupMenu, in view: NSView) {
        let bounds = popup.bounds
        rect = view.isFlipped ? bounds : CGRect(x: bounds.minX, y: view.bounds.height - bounds.maxY, width: bounds.width,
                                                 height: bounds.height)
        self.view = view
        selected = popup.selected
        rightAligned = popup.rightAligned
        let choice = Choice()
        self.choice = choice
        menu = Self.menu(for: popup, choice: choice)
    }

    /// The items as rows tagged with their index (a separator too, so tags never collide).
    static func menu(for popup: ChromiumHostPopupMenu, choice: Choice) -> NSMenu {
        let menu = NSMenu(title: "")
        menu.autoenablesItems = false
        // 0 is the menu's own size; the page's size otherwise, as its <select> shows it.
        let font = NSFont.menuFont(ofSize: CGFloat(max(popup.fontSize, 0)))
        for (index, item) in popup.items.enumerated() {
            let row = item.kind == .separator ? NSMenuItem.separator() : self.row(item, font: font, popup: popup, choice: choice)
            row.tag = index
            menu.addItem(row)
        }
        return menu
    }

    private static func row(_ item: ChromiumHostPopupMenu.Item, font: NSFont, popup: ChromiumHostPopupMenu,
                            choice: Choice) -> NSMenuItem {
        let row = NSMenuItem(title: item.label, action: #selector(Choice.chose(_:)), keyEquivalent: "")
        row.target = choice
        row.isEnabled = item.isChoosable
        if !item.toolTip.isEmpty { row.toolTip = item.toolTip }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = popup.rightAligned ? .right : .left
        let direction: NSWritingDirection = item.rtl ? .rightToLeft : .leftToRight
        paragraph.baseWritingDirection = direction
        var attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: paragraph, .font: font]
        if item.directionOverride {
            attributes[.writingDirection] = [NSNumber(value: direction.rawValue | NSWritingDirectionFormatType.override.rawValue)]
        }
        row.attributedTitle = NSAttributedString(string: item.label, attributes: attributes)
        // Type-select matches the title, which the attributed title does not show: without the
        // label's leading and trailing space, as Chrome sets it.
        row.title = item.label.trimmingCharacters(in: .whitespaces)
        return row
    }

    /// Tracks the menu over the `<select>` until it closes: the chosen row's index, nil for none. As in
    /// Chrome, the cell runs in a view of the `<select>`'s rect: near the Dock AppKit pops the menu up
    /// above the view it is given, which then is the `<select>`, not the whole page.
    func track() -> Int? {
        let cell = NSPopUpButtonCell(textCell: "", pullsDown: false)
        cell.menu = menu
        // No row has tag -1: no selection.
        cell.selectItem(withTag: selected)
        if rightAligned {
            cell.userInterfaceLayoutDirection = .rightToLeft
            menu.userInterfaceLayoutDirection = .rightToLeft
        }
        let anchor = NSView(frame: rect)
        view.addSubview(anchor)
        defer { anchor.removeFromSuperview() }
        cell.attachPopUp(withFrame: anchor.bounds, in: anchor)
        cell.performClick(withFrame: anchor.bounds, in: anchor)
        cell.dismissPopUp()
        return choice.index
    }
}

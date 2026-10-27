import CoreGraphics
import Foundation

/// What the page asks the viewer for, as the host's `rb.*` messages carry it
/// (plans/cmux-next/remote-tab-protocol.md section 4; cmux-remote-browser `proto.rs`):
/// a context menu or `<select>` (`rb.menu.show`), a JavaScript dialog (`rb.dialog.show`)
/// and a new tab or window (`rb.open_tab`). The Mac's viewer reads the same messages
/// (CmuxNextRemoteBrowser `RbMenu`, `RbDialog`, `RbClientEffect.openTab`).

/// One menu entry (`MenuItem`).
public struct RemoteBrowserMenuItem: Sendable, Equatable, Identifiable {
    public var id: Int64
    /// `command`, `check`, `radio`, `separator`, `submenu`, `group` (an optgroup), `option`.
    public var type: String
    public var label: String
    public var enabled: Bool
    public var checked: Bool
    public var items: [RemoteBrowserMenuItem]

    public init(id: Int64, type: String, label: String, enabled: Bool = true, checked: Bool = false,
                items: [RemoteBrowserMenuItem] = []) {
        self.id = id
        self.type = type
        self.label = label
        self.enabled = enabled
        self.checked = checked
        self.items = items
    }

    init?(json: [String: Any]) {
        guard let id = Self.int64(json["id"]), let type = json["type"] as? String else { return nil }
        self.id = id
        self.type = type
        label = Self.withoutMnemonic(json["label"] as? String ?? "")
        enabled = json["enabled"] as? Bool ?? true
        checked = json["checked"] as? Bool ?? false
        items = (json["items"] as? [[String: Any]] ?? []).compactMap(RemoteBrowserMenuItem.init(json:))
    }

    /// Chromium's labels mark their keyboard mnemonic with `&` ("Open Link in New &Tab";
    /// `&&` is a literal ampersand). iOS menus have no mnemonics: the label reads plainly.
    static func withoutMnemonic(_ label: String) -> String {
        var out = ""
        var pending = false
        for character in label {
            if character == "&", !pending {
                pending = true
                continue
            }
            pending = false
            out.append(character)
        }
        return out
    }

    static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber: number.int64Value
        case let number as Int: Int64(number)
        default: nil
        }
    }
}

/// A context menu or `<select>` popup (`Menu`).
public struct RemoteBrowserMenu: Sendable, Equatable {
    public enum Kind: String, Sendable { case context, select }

    public var kind: Kind
    /// Where it opens, in the page's CSS pixels.
    public var anchor: CGRect
    public var items: [RemoteBrowserMenuItem]
    /// `<select>`: the selected option's index.
    public var selected: Int?
    /// `<select multiple>`.
    public var multiple: Bool

    public init(kind: Kind, anchor: CGRect = .zero, items: [RemoteBrowserMenuItem], selected: Int? = nil, multiple: Bool = false) {
        self.kind = kind
        self.anchor = anchor
        self.items = items
        self.selected = selected
        self.multiple = multiple
    }

    init?(json: [String: Any]) {
        guard let kind = (json["kind"] as? String).flatMap(Kind.init(rawValue:)) else { return nil }
        self.kind = kind
        let anchor = json["anchor"] as? [String: Any] ?? [:]
        func number(_ key: String) -> Double { (anchor[key] as? NSNumber)?.doubleValue ?? 0 }
        self.anchor = CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height"))
        items = (json["items"] as? [[String: Any]] ?? []).compactMap(RemoteBrowserMenuItem.init(json:))
        selected = (json["selected"] as? NSNumber)?.intValue
        multiple = json["multiple"] as? Bool ?? false
    }

    /// Every command id the menu offers, submenus included (the choices it accepts).
    var commandIDs: Set<Int64> {
        var ids = Set<Int64>()
        func walk(_ items: [RemoteBrowserMenuItem]) {
            for item in items {
                if ["command", "check", "radio"].contains(item.type) { ids.insert(item.id) }
                walk(item.items)
            }
        }
        walk(items)
        return ids
    }

    /// The rows the phone shows of a page's context menu. Chromium runs each command on
    /// the Mac, so a row whose work lands on the Mac's own pasteboard, disk, printer or
    /// developer tools (Copy Link Address, Save Image As…, Copy, Paste, Print…, Inspect)
    /// would do nothing the person sees on the iPhone: those rows are left out (never a
    /// control that does nothing). Separators are kept only between rows.
    public var phoneItems: [RemoteBrowserMenuItem] {
        Self.phoneRows(items)
    }

    static func phoneRows(_ items: [RemoteBrowserMenuItem]) -> [RemoteBrowserMenuItem] {
        var rows: [RemoteBrowserMenuItem] = []
        for var item in items {
            if item.type == "separator" {
                if rows.last.map({ $0.type == "separator" }) ?? true { continue }
                rows.append(item)
                continue
            }
            if macOnlyCommands.contains(item.id) { continue }
            if item.type == "submenu" {
                item.items = phoneRows(item.items)
                if item.items.allSatisfy({ $0.type == "separator" }) { continue }
            }
            rows.append(item)
        }
        if rows.last?.type == "separator" { rows.removeLast() }
        return rows
    }

    /// Chromium (chrome/app/chrome_command_ids.h) and CEF (`cef_menu_id_t`) commands that
    /// act on the Mac itself, not on the page.
    static let macOnlyCommands: Set<Int64> = [
        50102, // IDC_CONTENT_CONTEXT_OPENLINKOFFTHERECORD (an incognito window on the Mac)
        50103, // IDC_CONTENT_CONTEXT_SAVELINKAS
        50104, // IDC_CONTENT_CONTEXT_COPYLINKLOCATION
        50107, // IDC_CONTENT_CONTEXT_COPYLINKTEXT
        50110, // IDC_CONTENT_CONTEXT_SAVEAVAS
        50111, // IDC_CONTENT_CONTEXT_COPYAVLOCATION
        50120, // IDC_CONTENT_CONTEXT_SAVEIMAGEAS
        50121, // IDC_CONTENT_CONTEXT_COPYIMAGELOCATION
        50122, // IDC_CONTENT_CONTEXT_COPYIMAGE
        50158, // IDC_CONTENT_CONTEXT_COPYLINKTOTEXT (Copy Link to Highlight)
        50150, // IDC_CONTENT_CONTEXT_COPY
        50151, // IDC_CONTENT_CONTEXT_CUT
        50152, // IDC_CONTENT_CONTEXT_PASTE
        50153, // IDC_CONTENT_CONTEXT_PASTE_AND_MATCH_STYLE
        50162, // IDC_CONTENT_CONTEXT_INSPECTELEMENT
        50165, // IDC_CONTENT_CONTEXT_LOOK_UP
        50180, 50181, 50182, // the Speech submenu: Start and Stop Speaking speak on the Mac
        35003, // IDC_PRINT
        35004, // IDC_SAVE_PAGE
        112, 113, 114, // MENU_ID_CUT, MENU_ID_COPY, MENU_ID_PASTE
        131, // MENU_ID_PRINT
    ]

    /// Whether `choice` is one this menu offered (the viewer's own check of
    /// remote-tab-protocol.md 5.2: an offer it never made is not sent).
    func accepts(_ choice: RemoteBrowserMenuChoice) -> Bool {
        switch choice {
        case .cancel:
            true
        case let .command(id):
            kind == .context && commandIDs.contains(id)
        case let .indices(indices):
            kind == .select && Set(indices).count == indices.count && indices.allSatisfy { $0 >= 0 && $0 < items.count }
                && (multiple || indices.count == 1)
        }
    }
}

/// The person's answer to a menu (`MenuChoice`).
public enum RemoteBrowserMenuChoice: Sendable, Equatable {
    case cancel
    case command(Int64)
    case indices([Int])

    var json: [String: Any] {
        switch self {
        case .cancel: ["choice": "cancel"]
        case let .command(id): ["choice": "command", "id": id]
        case let .indices(indices): ["choice": "indices", "indices": indices]
        }
    }
}

/// A JavaScript dialog (`Dialog`).
public struct RemoteBrowserDialog: Sendable, Equatable {
    public enum Kind: String, Sendable { case alert, confirm, prompt, beforeunload }

    public var kind: Kind
    public var origin: String
    public var message: String
    public var defaultText: String?
    /// `beforeunload` for a reload (its button says Reload, else Leave).
    public var isReload: Bool

    public init(kind: Kind, origin: String, message: String, defaultText: String? = nil, isReload: Bool = false) {
        self.kind = kind
        self.origin = origin
        self.message = message
        self.defaultText = defaultText
        self.isReload = isReload
    }

    init?(json: [String: Any]) {
        guard let kind = (json["kind"] as? String).flatMap(Kind.init(rawValue:)) else { return nil }
        self.kind = kind
        origin = json["origin"] as? String ?? ""
        message = json["message"] as? String ?? ""
        defaultText = json["default_text"] as? String
        isReload = json["is_reload"] as? Bool ?? false
    }

    /// The alert's title: the page's origin, as the Mac's dialog names it.
    public var title: String {
        origin.isEmpty ? String(localized: "This page says") : origin
    }

    /// The accepting button: OK, or Leave / Reload for a page that asks before it goes.
    public var acceptTitle: String {
        guard kind == .beforeunload else { return String(localized: "OK") }
        return isReload ? String(localized: "Reload") : String(localized: "Leave")
    }

    /// An alert has only OK; the rest can be declined.
    public var hasCancel: Bool { kind != .alert }
}

/// A page's request for a new tab or window (`rb.open_tab`).
public struct RemoteBrowserOpenTab: Sendable, Equatable {
    public enum Disposition: String, Sendable { case foregroundTab = "foreground_tab", backgroundTab = "background_tab", newWindow = "new_window", popup }

    public var request: UInt64
    public var url: String
    public var disposition: Disposition
    public var userGesture: Bool

    public init(request: UInt64, url: String, disposition: Disposition, userGesture: Bool) {
        self.request = request
        self.url = url
        self.disposition = disposition
        self.userGesture = userGesture
    }

    init?(json: [String: Any]) {
        guard let request = (json["request"] as? NSNumber)?.uint64Value, let url = json["url"] as? String else { return nil }
        self.request = request
        self.url = url
        disposition = (json["disposition"] as? String).flatMap(Disposition.init(rawValue:)) ?? .foregroundTab
        userGesture = json["user_gesture"] as? Bool ?? false
    }

    /// A background tab stays behind the page; a tab, window or popup comes to the front
    /// (the phone has one window: each is a tab).
    public var opensInBackground: Bool { disposition == .backgroundTab }
}

extension RemoteBrowserWire {
    public func menuResult(token: UInt64, choice: RemoteBrowserMenuChoice) -> Data {
        encodeJSON(["t": "rb.menu.result", "token": token, "choice": choice.json])
    }

    public func dialogResult(token: UInt64, accept: Bool, text: String?) -> Data {
        encodeJSON(["t": "rb.dialog.result", "token": token, "accept": accept, "text": text.map { $0 as Any } ?? NSNull()])
    }

    /// `tab`: the new tab's id; nil with `refused` when none opened.
    public func openTabResult(request: UInt64, tab: String?, refused: String?) -> Data {
        encodeJSON(["t": "rb.open_tab.result", "request": request,
                    "tab": tab.map { $0 as Any } ?? NSNull(), "refused": refused.map { $0 as Any } ?? NSNull()])
    }

    /// A secondary-button click at CSS pixels (the long press that asks for the page's menu).
    public func secondaryClick(x: Double, y: Double, down: Bool) -> Data {
        encodeJSON(["e": "pointer", "surface": 0, "kind": down ? "down" : "up", "x": x, "y": y, "button": 2,
                    "buttons": down ? 2 : 0, "click_count": 1, "modifiers": 0, "pointer_type": "mouse"])
    }

    func encodeJSON(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

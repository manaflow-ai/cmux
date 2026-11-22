public import AppKit

/// One item of an engine's page context menu (Chromium's model, including
/// `chrome.contextMenus` items that extensions add).
public nonisolated struct BrowserContextMenuItem: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case command, check, radio, separator, submenu
    }

    public var id: Int
    /// Display title; `&` mnemonics already removed.
    public var title: String
    public var kind: Kind
    public var isEnabled: Bool
    public var isChecked: Bool
    public var children: [BrowserContextMenuItem]

    public init(id: Int, title: String, kind: Kind = .command, isEnabled: Bool = true, isChecked: Bool = false,
                children: [BrowserContextMenuItem] = []) {
        self.id = id
        self.title = title
        self.kind = kind
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.children = children
    }

    /// Chromium labels mark mnemonics with `&` and escape a literal one as `&&`.
    static func stripMnemonics(_ label: String) -> String {
        var result = ""
        var iterator = label.makeIterator()
        while let character = iterator.next() {
            if character == "&" {
                if let next = iterator.next() { result.append(next) }
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// Decodes the shim's JSON (`CMUX_SHIM_CONTEXT_MENU` items).
    static func decodeList(_ json: String) -> [BrowserContextMenuItem] {
        guard let data = json.data(using: .utf8), let items = try? JSONDecoder().decode([Wire].self, from: data) else {
            return []
        }
        return items.map(\.item)
    }

    private struct Wire: Decodable {
        var id: Int
        var label: String?
        var type: String?
        var enabled: Bool?
        var checked: Bool?
        var items: [Wire]?

        var item: BrowserContextMenuItem {
            BrowserContextMenuItem(
                id: id, title: BrowserContextMenuItem.stripMnemonics(label ?? ""),
                kind: Kind(rawValue: type ?? "") ?? .command, isEnabled: enabled ?? true,
                isChecked: checked ?? false, children: (items ?? []).map(\.item)
            )
        }
    }
}

/// What was right-clicked: a link (its address and text), an image, the
/// selection. Both engines fill it (Chromium from its menu params, WebKit
/// from the `contextmenu` event, `WebKitContextHit`), and the host builds
/// the same link, image and selection rows from it.
public nonisolated struct BrowserContextMenuTarget: Hashable, Sendable {
    public var linkURL: URL?
    /// The link's visible text; empty when unknown.
    public var linkText: String
    /// The media element's address (an image's source, a video's).
    public var sourceURL: URL?
    /// The right-clicked image's address; nil for other media.
    public var imageURL: URL?
    public var pageURL: URL?
    public var selection: String
    public var isEditable: Bool

    public init(linkURL: URL? = nil, linkText: String = "", sourceURL: URL? = nil, imageURL: URL? = nil, pageURL: URL? = nil,
                selection: String = "", isEditable: Bool = false) {
        self.linkURL = linkURL
        self.linkText = linkText
        self.sourceURL = sourceURL
        self.imageURL = imageURL
        self.pageURL = pageURL
        self.selection = selection
        self.isEditable = isEditable
    }

    /// Chromium's context menu params (`CMUX_SHIM_CONTEXT_MENU`). Chromium
    /// does not report the link's text (`CEFTab.linkText(for:)` reads it).
    public static func chromium(_ json: String) -> BrowserContextMenuTarget {
        guard let data = json.data(using: .utf8),
              let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return BrowserContextMenuTarget() }
        func url(_ text: String?) -> URL? { text.flatMap { $0.isEmpty ? nil : URL(string: $0) } }
        let source = url(wire.source_url)
        // CEF's CM_MEDIATYPE_IMAGE.
        return BrowserContextMenuTarget(linkURL: url(wire.link_url), sourceURL: source, imageURL: wire.media_type == 1 ? source : nil,
                                        pageURL: url(wire.page_url), selection: wire.selection ?? "", isEditable: wire.editable ?? false)
    }

    private struct Wire: Decodable {
        var link_url: String?
        var source_url: String?
        var page_url: String?
        var selection: String?
        var editable: Bool?
        var media_type: Int?
    }
}

/// A page asks for its context menu. The host shows `items` (it may add its
/// own) at `location` and calls `complete` exactly once with the chosen
/// item's id, or nil when the menu was dismissed.
@MainActor
public final class BrowserContextMenuRequest {
    public let items: [BrowserContextMenuItem]
    public let target: BrowserContextMenuTarget
    /// In the tab's `contentView` coordinates.
    public let location: CGPoint
    /// Set when the engine shows its own menu (WebKit): the host passes its
    /// leading rows here at once instead of presenting a menu.
    public let insertLeading: (([NSMenuItem]) -> Void)?
    private var completion: ((Int?) -> Void)?

    public init(items: [BrowserContextMenuItem], target: BrowserContextMenuTarget, location: CGPoint,
                insertLeading: (([NSMenuItem]) -> Void)? = nil,
                completion: @escaping (Int?) -> Void) {
        self.items = items
        self.target = target
        self.location = location
        self.insertLeading = insertLeading
        self.completion = completion
    }

    public func complete(_ id: Int?) {
        let completion = completion
        self.completion = nil
        completion?(id)
    }

    isolated deinit {
        // A host that drops the request dismisses the menu.
        completion?(nil)
    }
}

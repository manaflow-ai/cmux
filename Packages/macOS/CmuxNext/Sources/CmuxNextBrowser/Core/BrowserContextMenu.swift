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
    /// False for a row Chromium keeps in its model but does not show (an
    /// extension item created with `visible: false`). ``decodeList(_:)``
    /// drops these rows, as Chrome's menu does.
    public var isVisible: Bool
    public var children: [BrowserContextMenuItem]
    /// The image Chrome shows before the title: an extension's icon on its
    /// top-level row, or the vector icon of a Chrome row such as Translate.
    /// CEF's menu model carries no images, so the host fills this in
    /// (``BrowserExtensionMenuIcons``, ``withChromeIcons(_:)``).
    public var icon: BrowserContextMenuIcon?
    /// The extension that added this top-level row, when the host could tell.
    public var extensionID: String?

    public init(id: Int, title: String, kind: Kind = .command, isEnabled: Bool = true, isChecked: Bool = false,
                isVisible: Bool = true, children: [BrowserContextMenuItem] = [], icon: BrowserContextMenuIcon? = nil,
                extensionID: String? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.isVisible = isVisible
        self.children = children
        self.icon = icon
        self.extensionID = extensionID
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

    /// Decodes the shim's JSON (`CMUX_SHIM_CONTEXT_MENU` items), keeping
    /// only the rows Chrome would show (``visibleItems(_:)``).
    static func decodeList(_ json: String) -> [BrowserContextMenuItem] {
        guard let data = json.data(using: .utf8), let items = try? JSONDecoder().decode([Wire].self, from: data) else {
            return []
        }
        return visibleItems(items.map(\.item))
    }

    /// Pure: `items` as Chrome's menu shows them: no hidden row, no submenu
    /// without a visible child (Chromium's `HasVisibleItems`), and no
    /// leading, trailing or doubled separator at any level.
    static func visibleItems(_ items: [BrowserContextMenuItem]) -> [BrowserContextMenuItem] {
        var result: [BrowserContextMenuItem] = []
        for var item in items where item.isVisible {
            if item.kind == .submenu {
                item.children = visibleItems(item.children)
                if !item.children.contains(where: { $0.kind != .separator }) { continue }
            }
            if item.kind == .separator, result.last.map({ $0.kind == .separator }) ?? true { continue }
            result.append(item)
        }
        if result.last?.kind == .separator { result.removeLast() }
        return result
    }

    private struct Wire: Decodable {
        var id: Int
        var label: String?
        var type: String?
        var enabled: Bool?
        var checked: Bool?
        var visible: Bool?
        var items: [Wire]?

        var item: BrowserContextMenuItem {
            BrowserContextMenuItem(
                id: id, title: BrowserContextMenuItem.stripMnemonics(label ?? ""),
                kind: Kind(rawValue: type ?? "") ?? .command, isEnabled: enabled ?? true,
                isChecked: checked ?? false, isVisible: visible ?? true, children: (items ?? []).map(\.item)
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

    /// The selection on one line, at most `limit` characters (Chrome's menu rows quote it the same way).
    public func selectionSnippet(limit: Int = 50) -> String {
        let line = selection.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
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
/// item's id, or nil when the menu was dismissed. A request made with no
/// `completion` owes the engine no answer, and `complete` does nothing.
@MainActor
public final class BrowserContextMenuRequest {
    public let items: [BrowserContextMenuItem]
    public let target: BrowserContextMenuTarget
    /// In the tab's `contentView` coordinates.
    public let location: CGPoint
    /// Set when the engine shows its own menu (WebKit): the host passes its
    /// leading rows here at once instead of presenting a menu.
    public let insertLeading: (([NSMenuItem]) -> Void)?
    /// A host that drops the request unanswered dismisses the menu: the token answers nil
    /// when it is released with the request. Nil when the engine needs no answer, so a
    /// released request queues nothing.
    private let reply: BrowserContextMenuCompletion?

    /// - Parameter completion: Runs once on the main actor with the chosen item's id, or nil
    ///   when the menu was dismissed or the request was released unanswered. Pass nil when the
    ///   engine waits for no answer (WebKit shows its own menu and takes `insertLeading`).
    public init(items: [BrowserContextMenuItem], target: BrowserContextMenuTarget, location: CGPoint,
                insertLeading: (([NSMenuItem]) -> Void)? = nil,
                completion: ((Int?) -> Void)?) {
        self.items = items
        self.target = target
        self.location = location
        self.insertLeading = insertLeading
        if let completion {
            reply = BrowserContextMenuCompletion { completion($0) }
        } else {
            reply = nil
        }
    }

    public func complete(_ id: Int?) {
        reply?.complete(id)
    }
}

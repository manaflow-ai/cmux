import AppKit
import WebKit

/// What a right-click in a WebKit page hit, without private WebKit API: a
/// script in its own content world listens for `contextmenu` in the
/// capture phase (before the page's handlers) and posts the link's address
/// and text, the image's address, the selection and whether the target is
/// editable. The report reaches the tab before WebKit opens its menu (the
/// web process sends the message first, on the same connection); the menu
/// then swaps WebKit's link, image and selection rows for the host's rows
/// (`BrowserHitMenu` in the App), the same rows Chromium shows.
nonisolated enum WebKitContextHit {
    static let handlerName = "cmuxContextHit"
    /// A world of its own: page scripts cannot call the handler or replace
    /// the listener; the DOM and its events are shared.
    @MainActor static var world: WKContentWorld { WKContentWorld.world(name: "cmux-context-hit") }
    /// A report older than this when the menu opens belongs to another click.
    static let freshness: Duration = .seconds(1)

    static let source = #"""
    (() => {
      if (window.__cmuxContextHit) return;
      window.__cmuxContextHit = true;
      const isEditable = (node) => !!node && node.nodeType === 1 &&
        (node.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(node.tagName));
      addEventListener('contextmenu', (event) => {
        let link = null, image = null;
        for (const node of event.composedPath()) {
          if (!node || node.nodeType !== 1) continue;
          if (!link && (node.tagName === 'A' || node.tagName === 'AREA') && typeof node.href === 'string' && node.href) link = node;
          if (!image && node.tagName === 'IMG') image = node;
        }
        const selection = String(getSelection() || '');
        try {
          window.webkit.messageHandlers.cmuxContextHit.postMessage({
            link: link ? link.href : '',
            linkText: link ? (link.innerText || link.textContent || '').trim().slice(0, 4096) : '',
            image: image ? (image.currentSrc || image.src || '') : '',
            selection: selection.slice(0, 65536),
            editable: isEditable(event.target),
          });
        } catch (_) {}
      }, true);
    })();
    """#

    /// The script, in every frame from document start.
    @MainActor static func install(_ handler: any WKScriptMessageHandler, into controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        controller.add(WeakScriptMessageHandler(handler), contentWorld: world, name: handlerName)
    }

    // MARK: Menu rows

    static let linkRows: Set<String> = [
        "WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierOpenLinkInNewWindow",
        "WKMenuItemIdentifierDownloadLinkedFile", "WKMenuItemIdentifierCopyLink",
    ]
    static let imageRows: Set<String> = [
        "WKMenuItemIdentifierOpenImageInNewWindow", "WKMenuItemIdentifierDownloadImage", "WKMenuItemIdentifierCopyImage",
    ]
    /// Only outside editable fields, where WebKit's Cut, Copy and Paste stay together.
    static let selectionRows: Set<String> = [
        "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierLookUp", "WKMenuItemIdentifierSearchWeb",
    ]

    /// Removes WebKit's rows that the host's rows replace for `hit`, with
    /// no leading, trailing or doubled separators left behind.
    @MainActor static func removeEngineRows(from menu: NSMenu, for hit: BrowserContextMenuTarget) {
        var dropped = linkRows.union(imageRows)
        if !hit.isEditable { dropped.formUnion(selectionRows) }
        for item in menu.items where item.identifier.map({ dropped.contains($0.rawValue) }) == true {
            menu.removeItem(item)
        }
        trimSeparators(menu)
    }

    /// Puts `rows` at the top of `menu`, a separator after them.
    @MainActor static func insert(_ rows: [NSMenuItem], into menu: NSMenu) {
        guard !rows.isEmpty else { return }
        if menu.numberOfItems > 0 { menu.insertItem(.separator(), at: 0) }
        for (index, row) in rows.enumerated() { menu.insertItem(row, at: index) }
        trimSeparators(menu)
    }

    @MainActor private static func trimSeparators(_ menu: NSMenu) {
        var previousSeparator = true
        for item in menu.items {
            if item.isSeparatorItem, previousSeparator { menu.removeItem(item) } else { previousSeparator = item.isSeparatorItem }
        }
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.numberOfItems - 1) }
    }
}

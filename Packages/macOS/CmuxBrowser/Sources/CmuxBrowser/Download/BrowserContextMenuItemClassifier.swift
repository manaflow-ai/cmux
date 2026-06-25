public import AppKit

/// Pure predicate/tokenizer logic for the browser context-menu download and copy
/// paths, classifying an `NSMenuItem` by its identifier, title, and action
/// selector name.
///
/// Lifted byte-faithfully out of the app-target `CmuxWebView` so the
/// menu-item-matching logic that decides whether a WebKit context-menu item is
/// the native "Download Image", "Download Linked File", or "Copy Image" command
/// lives in `CmuxBrowser` beside `BrowserDownloadURLClassifier`. `CmuxWebView`'s
/// `willOpenMenu` hook keeps the side effects (mutating `item.target`/`action`,
/// reading objc associated objects, debug logging) and forwards each predicate
/// here.
///
/// Every method is a deterministic transform over the menu item's three token
/// strings (identifier raw value, title, action selector name) with zero instance
/// reference state, so this is a real value type, not a static-only namespace of
/// utilities: callers construct `BrowserContextMenuItemClassifier()` and call
/// `isDownloadImageMenuItem(item)` etc. A pure value type with no stored state,
/// so it is `Sendable` and `nonisolated`.
public nonisolated struct BrowserContextMenuItemClassifier: Sendable {
    /// Creates a classifier.
    public init() {}

    /// The selector's name via `NSStringFromSelector`, or `"nil"` when the
    /// selector is absent (the placeholder used in debug log lines).
    public func selectorName(_ selector: Selector?) -> String {
        guard let selector else { return "nil" }
        return NSStringFromSelector(selector)
    }

    /// Lowercases the value and strips every non-alphanumeric scalar, producing the
    /// canonical token compared against the download/copy match substrings.
    public func normalizedContextMenuToken(_ value: String?) -> String {
        guard let value else { return "" }
        let lowered = value.lowercased()
        let alphanumerics = CharacterSet.alphanumerics
        let scalars = lowered.unicodeScalars.filter { alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Whether the item is WebKit's native "Download Image" command, matched on the
    /// identifier, title, or action selector name containing `downloadimage`.
    public func isDownloadImageMenuItem(_ item: NSMenuItem) -> Bool {
        let identifier = normalizedContextMenuToken(item.identifier?.rawValue)
        if identifier.contains("downloadimage") {
            return true
        }

        let title = normalizedContextMenuToken(item.title)
        if title.contains("downloadimage") {
            return true
        }

        if let action = item.action {
            let actionName = normalizedContextMenuToken(NSStringFromSelector(action))
            if actionName.contains("downloadimage") {
                return true
            }
        }

        return false
    }

    /// Whether the item is WebKit's native "Download Linked File" command, matched
    /// on the identifier, title, or action selector name containing
    /// `downloadlinkedfile` or `downloadlinktodisk`.
    public func isDownloadLinkedFileMenuItem(_ item: NSMenuItem) -> Bool {
        let identifier = normalizedContextMenuToken(item.identifier?.rawValue)
        if identifier.contains("downloadlinkedfile")
            || identifier.contains("downloadlinktodisk") {
            return true
        }

        let title = normalizedContextMenuToken(item.title)
        if title.contains("downloadlinkedfile")
            || title.contains("downloadlinktodisk") {
            return true
        }

        if let action = item.action {
            let actionName = normalizedContextMenuToken(NSStringFromSelector(action))
            if actionName.contains("downloadlinkedfile")
                || actionName.contains("downloadlinktodisk") {
                return true
            }
        }

        return false
    }

    /// Whether the item is WebKit's native "Copy Image" command (the bitmap copy),
    /// matched on a token equal to `copyimage` or containing
    /// `copyimagetoclipboard`/`copyimage`. Returns `false` for the
    /// copy-image-address/url/location variants so only the bitmap copy is hooked.
    public func isCopyImageMenuItem(_ item: NSMenuItem) -> Bool {
        let tokens = [
            normalizedContextMenuToken(item.identifier?.rawValue),
            normalizedContextMenuToken(item.title),
            item.action.map { normalizedContextMenuToken(NSStringFromSelector($0)) } ?? "",
        ]

        for token in tokens where !token.isEmpty {
            if token.contains("copyimageaddress")
                || token.contains("copyimageurl")
                || token.contains("copyimagelocation") {
                return false
            }
            if token == "copyimage"
                || token.contains("copyimagetoclipboard")
                || token.contains("copyimage") {
                return true
            }
        }

        return false
    }

    /// Whether the item is WebKit's native "Open Link" command, matched on the
    /// `WKMenuItemIdentifierOpenLink` identifier or the verbatim English title
    /// `"Open Link"`. `CmuxWebView` uses this as the insertion anchor for its own
    /// "Open Link in Default Browser" item (inserted just after this item), so the
    /// English-title fallback intentionally mirrors WebKit's own untranslated
    /// string rather than a localized cmux key.
    public func isOpenLinkMenuItem(_ item: NSMenuItem) -> Bool {
        item.identifier?.rawValue == "WKMenuItemIdentifierOpenLink"
            || item.title == "Open Link"
    }

    /// Whether the item is WebKit's native "Open Link in New Window" command,
    /// matched on the `WKMenuItemIdentifierOpenLinkInNewWindow` identifier or a
    /// title containing the verbatim English phrase `"Open Link in New Window"`.
    /// `CmuxWebView` retargets this item to open a tab instead of a popup window;
    /// the English-title fallback mirrors WebKit's own untranslated string.
    public func isOpenLinkInNewWindowMenuItem(_ item: NSMenuItem) -> Bool {
        item.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow"
            || item.title.contains("Open Link in New Window")
    }
}

/// Classifies a WebKit browser context-menu item as one of the download/copy
/// actions cmux retargets, using only string-token matching over the item's
/// identifier, title, and action-selector name. The AppKit `NSMenuItem` stays in
/// the app; the app passes the three string components and reads back the boolean
/// classifications. WebKit varies these across OS versions (localized titles,
/// `WKMenuItemIdentifier*` identifiers, private selector names), so each token is
/// matched after normalization (see ``Swift/String/normalizedBrowserContextMenuToken``).
public struct BrowserContextMenuItemClassifier {
    private let identifierToken: String
    private let titleToken: String
    private let actionToken: String

    /// Builds a classifier from a menu item's raw string components. Any component
    /// may be `nil` (a missing identifier or action), which normalizes to an empty
    /// token that never matches.
    public init(identifier: String?, title: String?, actionName: String?) {
        identifierToken = (identifier ?? "").normalizedBrowserContextMenuToken
        titleToken = (title ?? "").normalizedBrowserContextMenuToken
        actionToken = (actionName ?? "").normalizedBrowserContextMenuToken
    }

    /// `true` when the item is WebKit's "Download Image" action.
    public var isDownloadImageMenuItem: Bool {
        if identifierToken.contains("downloadimage") {
            return true
        }
        if titleToken.contains("downloadimage") {
            return true
        }
        if actionToken.contains("downloadimage") {
            return true
        }
        return false
    }

    /// `true` when the item is WebKit's "Download Linked File" action (also
    /// spelled "Download Link To Disk" on some OS versions).
    public var isDownloadLinkedFileMenuItem: Bool {
        if identifierToken.contains("downloadlinkedfile")
            || identifierToken.contains("downloadlinktodisk") {
            return true
        }
        if titleToken.contains("downloadlinkedfile")
            || titleToken.contains("downloadlinktodisk") {
            return true
        }
        if actionToken.contains("downloadlinkedfile")
            || actionToken.contains("downloadlinktodisk") {
            return true
        }
        return false
    }

    /// `true` when the item is WebKit's "Copy Image" action. The "copy image
    /// address/url/location" variants copy a URL rather than the image bytes, so
    /// they are excluded; the first matching token (identifier, then title, then
    /// action) decides.
    public var isCopyImageMenuItem: Bool {
        let tokens = [identifierToken, titleToken, actionToken]

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
}

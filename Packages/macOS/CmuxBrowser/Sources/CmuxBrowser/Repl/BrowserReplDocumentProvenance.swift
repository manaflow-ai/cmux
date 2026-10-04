public import WebKit

/// Who made a document of an opaque origin.
public indirect enum BrowserReplDocumentMaker: Sendable, Equatable {
    /// The app loaded it (the agent's or the person's own navigation).
    case app
    /// A page made it (a navigation that page started): the document of
    /// that page, which has an origin or a URL the policy can judge.
    case page(BrowserReplFrameDocument)
    /// cmux cannot tell (no record, or a record that was dropped).
    case unknown
}

/// Who made the opaque documents (`data:`, `about:` and `blob:` of an
/// opaque origin) of a web view's frames.
///
/// Such a document names no host, so the domain policy cannot judge it by
/// its URL or origin: a page the policy blocks can navigate its own frame
/// to `data:` and show its content there. The navigation delegate records
/// every navigation to such a URL (``note(_:in:)``) with the document that
/// started it (WebKit's record of the source frame), so the policy judges
/// the document by its maker (``BrowserReplDomainPolicy/blockReason(document:)``).
///
/// A frame's records are kept for the frame's life and never cleared: WebKit
/// does not tell the app which of a child frame's navigations committed, so
/// every maker a frame's opaque documents may have had counts. A frame with
/// too many makers, or a web view with too many frames, counts as unknown.
@MainActor
public final class BrowserReplDocumentProvenance {
    /// Makers per frame (`"main"` or the frame's id).
    private var makers: [String: [BrowserReplDocumentMaker]] = [:]

    static let maximumMakersPerFrame = 16
    static let maximumFrames = 1_024

    private static var associationKey: UInt8 = 0

    private static func of(_ webView: WKWebView, creating: Bool) -> BrowserReplDocumentProvenance? {
        if let existing = objc_getAssociatedObject(webView, &associationKey) as? BrowserReplDocumentProvenance {
            return existing
        }
        guard creating else { return nil }
        let created = BrowserReplDocumentProvenance()
        objc_setAssociatedObject(webView, &associationKey, created, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return created
    }

    static func frameKey(_ info: WKFrameInfo) -> String? {
        info.isMainFrame ? "main" : BrowserReplFrame.frameID(of: info)
    }

    /// The makers recorded for frame `key` (`"main"` or a frame id) of
    /// `webView`, or nil when none is.
    static func makers(ofFrame key: String, in webView: WKWebView) -> [BrowserReplDocumentMaker]? {
        of(webView, creating: false)?.makers[key]
    }

    /// The makers recorded for the frame `info` describes, or nil.
    static func makers(of info: WKFrameInfo) -> [BrowserReplDocumentMaker]? {
        guard let webView = info.webView, let key = frameKey(info) else { return nil }
        return makers(ofFrame: key, in: webView)
    }

    /// Records a navigation WebKit asks about in `webView`: one to a URL
    /// whose document is opaque, or takes its maker's origin, gets the
    /// document that started it as a maker of its frame. Call it for every
    /// navigation, also one that is then cancelled or held.
    public static func note(_ action: WKNavigationAction, in webView: WKWebView) {
        guard let target = action.targetFrame, let url = action.request.url,
              makesOpaqueDocument(url), let key = frameKey(target) else { return }
        let added: [BrowserReplDocumentMaker]
        if let source = action.value(forKey: "sourceFrame") as? WKFrameInfo {
            var document = BrowserReplFrameDocument(info: source)
            if document.isOpaque {
                // An opaque page's own makers made this one too.
                added = document.makers ?? (isInitialEmptyDocument(source) ? [.app] : [.unknown])
            } else {
                document.makers = nil
                added = [.page(document)]
            }
        } else {
            added = [.app]
        }
        of(target.webView ?? webView, creating: true)?.add(added, frame: key)
    }

    /// Whether a document at `url` is opaque or takes its maker's origin.
    static func makesOpaqueDocument(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "data", "about":
            return true
        case "blob":
            return BrowserReplDomainPolicy.blobOrigin(url.absoluteString) == nil
        default:
            return false
        }
    }

    /// A new web view's main frame before its first load: WebKit names it as
    /// the source of the app's first navigation.
    private static func isInitialEmptyDocument(_ info: WKFrameInfo) -> Bool {
        guard info.isMainFrame, info.webView?.backForwardList.currentItem == nil else { return false }
        let url = info.request.url?.absoluteString ?? ""
        return url.isEmpty || url == "about:blank"
    }

    private func add(_ added: [BrowserReplDocumentMaker], frame key: String) {
        if makers[key] == nil, makers.count >= Self.maximumFrames {
            // Dropped records count as unknown, which a locked policy refuses.
            makers.removeAll()
        }
        var list = makers[key] ?? []
        for maker in added where !list.contains(maker) { list.append(maker) }
        makers[key] = list.count > Self.maximumMakersPerFrame ? [.unknown] : list
    }
}

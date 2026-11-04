public import WebKit

/// Decides whether a secret may be typed into a tab now: the frame whose
/// document holds the focused element, which is where inserted text goes,
/// must have an origin, and a URL host, on the secret's domains
/// (``BrowserReplFrameDocument/isOn(secretDomains:)``).
///
/// A frame keeps its id when it navigates, so the frame tree can name a
/// document the frame no longer shows (`BrowserReplFrame.info`). The
/// origin and URL place are therefore read by the same evaluation that
/// finds the focus, in the document that holds it (`self.origin`, the
/// document's own origin, `"null"` when opaque, and `location`), never
/// from the tree. The URL's host is judged too: a page can relax
/// `document.domain` onto a parent domain on the secret's list. The checks run in
/// a content world page and agent code cannot reach.
@MainActor
public struct BrowserReplSecretTarget {
    /// The secret's name, for errors.
    public let name: String
    /// The secret's domains (`secretDomains` as the session sends them).
    public let domains: [BrowserReplDomainPattern]
    private let world: WKContentWorld
    /// Bounds each focus probe: WebKit drops a script's completion when a
    /// navigation replaces its document, and a busy page answers late.
    private let probe: BrowserReplScriptProbe
    /// Answers, in one frame's document, whether it holds the focused
    /// element (a function body returning a boolean). A document whose
    /// active element is a frame element
    /// (``BrowserReplFrameGate/frameElementTest(_:)``) is never asked: the
    /// focus is in that element's frame, which answers for itself.
    var focusProbe = Self.focusProbe

    static let focusProbe = """
    const el = document.activeElement;
    return document.hasFocus() && !!el;
    """

    /// - Parameters:
    ///   - domains: `secretDomains` as the session sends them.
    ///   - world: The driver's own content world.
    ///   - probe: Bounds each focus probe.
    public init(name: String, domains: [[String: Any]], world: WKContentWorld, probe: BrowserReplScriptProbe = BrowserReplScriptProbe()) {
        self.name = name
        self.domains = domains.compactMap(BrowserReplDomainPattern.from(json:))
        self.world = world
        self.probe = probe
    }

    /// Why a secret may not be typed into a tab whose live creating session
    /// is `creator` by the session `sessionID`, or nil. The page that
    /// receives a secret can send it on, and only the creating session's
    /// domain policy (its content rules) holds a tab's requests: a user's
    /// tab, or another session's, keeps its own. The session checks that
    /// its policy keeps its tabs on the secret's domains
    /// (`BrowserReplBoundary.prepare`).
    public static func tabRefusal(name: String, creator: String?, sessionID: String) -> BrowserReplDriverError? {
        guard creator != sessionID else { return nil }
        return BrowserReplDriverError(
            code: "invalid",
            message: "secret \"\(name)\" is typed only into a tab this session opened (tabs.open), where its domain policy keeps the page from sending it elsewhere; this tab is \(creator == nil ? "the user's" : "another session's")"
        )
    }

    /// Throws `invalid` unless the focused frame's origin and URL host are
    /// on the secret's domains, and `stale` when a frame does not answer within the
    /// probe's bound.
    /// - Parameter frames: The tab's frame tree, read just before.
    public func check(in webView: WKWebView, frames: [BrowserReplFrame]) async throws {
        // The document that answers "focused" names its own origin.
        // A focused `<iframe>`, `<frame>`, `<object>` or `<embed>` means the
        // focus is in its frame, never in this document.
        let source = """
        const __active = document.activeElement;
        if (\(BrowserReplFrameGate.frameElementTest("__active"))) return null;
        const focused = (() => {
        \(focusProbe)
        })();
        return focused ? [String(self.origin), location.protocol + "//" + location.host] : null;
        """
        var focused: BrowserReplFrameDocument?
        for frame in frames {
            guard let info = frame.info else { continue }
            let answer: Any?
            do {
                answer = try await probe.call(
                    source, arguments: [:], in: webView, frame: info, contentWorld: world,
                    what: "secret \"\(name)\" was not typed: frame \(frame.frameID) did not report its focus"
                )
            } catch let error as BrowserReplDriverError {
                throw error
            } catch {
                // A frame that has gone holds no focus.
                answer = nil
            }
            if let pair = answer as? [Any], pair.count == 2, let origin = pair[0] as? String, let place = pair[1] as? String {
                focused = BrowserReplFrameDocument(origin: origin, place: place.lowercased())
            }
        }
        guard let document = focused else {
            throw BrowserReplDriverError(code: "invalid", message: "secret \"\(name)\" was not typed: no focused field in the page")
        }
        guard document.isOn(secretDomains: domains) else {
            let list = domains.map(\.raw).joined(separator: ", ")
            let shown = Set([document.origin ?? "null", document.place]).sorted().joined(separator: " at ")
            throw BrowserReplDriverError(code: "invalid", message: "secret \"\(name)\" may not be typed into \(shown); its domains are \(list)")
        }
    }
}

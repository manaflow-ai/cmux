public import WebKit

/// Decides whether a secret may be typed into a tab now: the frame whose
/// document holds the focused element, which is where inserted text goes,
/// must have an origin on one of the secret's domains.
///
/// A frame keeps its id when it navigates, so the frame tree can name a
/// document the frame no longer shows (`BrowserReplFrame.info`). The
/// origin is therefore read by the same evaluation that finds the focus,
/// in the document that holds it (`self.origin`, the document's own
/// origin, `"null"` when opaque), never from the tree. The checks run in
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
    /// element (a function body returning a boolean).
    var focusProbe = Self.focusProbe

    static let focusProbe = """
    const el = document.activeElement;
    return document.hasFocus() && !!el && el.tagName !== "IFRAME" && el.tagName !== "FRAME";
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

    /// Throws `invalid` unless the focused frame's origin matches one of the
    /// secret's domains, and `stale` when a frame does not answer within the
    /// probe's bound.
    /// - Parameter frames: The tab's frame tree, read just before.
    public func check(in webView: WKWebView, frames: [BrowserReplFrame]) async throws {
        // The document that answers "focused" names its own origin.
        let source = "const focused = (() => {\n\(focusProbe)\n})();\nreturn focused ? String(self.origin) : null;"
        var focusedOrigin: String?
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
            if let origin = answer as? String { focusedOrigin = origin }
        }
        guard let origin = focusedOrigin else {
            throw BrowserReplDriverError(code: "invalid", message: "secret \"\(name)\" was not typed: no focused field in the page")
        }
        guard domains.contains(where: { $0.matches(origin: origin, secure: true) }) else {
            let list = domains.map(\.raw).joined(separator: ", ")
            throw BrowserReplDriverError(code: "invalid", message: "secret \"\(name)\" may not be typed into \(origin); its domains are \(list)")
        }
    }
}

public import WebKit

/// Decides whether a secret may be typed into a tab now: the frame whose
/// document holds the focused element, which is where inserted text goes,
/// must have an origin on one of the secret's domains.
///
/// The checks run in a content world page and agent code cannot reach.
@MainActor
public struct BrowserReplSecretTarget {
    /// The secret's name, for errors.
    public let name: String
    /// The secret's domains (`secretDomains` as the session sends them).
    public let domains: [BrowserReplDomainPattern]
    private let world: WKContentWorld
    /// Answers, in one frame's document, whether it holds the focused element.
    var focusProbe = Self.focusProbe

    static let focusProbe = """
    const el = document.activeElement;
    return document.hasFocus() && !!el && el.tagName !== "IFRAME" && el.tagName !== "FRAME";
    """

    /// - Parameters:
    ///   - domains: `secretDomains` as the session sends them.
    ///   - world: The driver's own content world.
    public init(name: String, domains: [[String: Any]], world: WKContentWorld) {
        self.name = name
        self.domains = domains.compactMap(BrowserReplDomainPattern.from(json:))
        self.world = world
    }

    /// Throws `invalid` unless the focused frame's origin matches one of the
    /// secret's domains.
    /// - Parameter frames: The tab's frame tree, read just before.
    public func check(in webView: WKWebView, frames: [BrowserReplFrame]) async throws {
        var focused: BrowserReplFrame?
        for frame in frames {
            guard let info = frame.info else { continue }
            let answer = try? await webView.callAsyncJavaScript(focusProbe, arguments: [:], in: info, contentWorld: world)
            if answer as? Bool == true { focused = frame }
        }
        guard let info = focused?.info, let origin = info.browserReplOrigin else {
            throw BrowserReplDriverError(code: "invalid", message: "secret \"\(name)\" was not typed: no focused field in the page")
        }
        guard domains.contains(where: { $0.matches(origin: origin, secure: true) }) else {
            let list = domains.map(\.raw).joined(separator: ", ")
            throw BrowserReplDriverError(code: "invalid", message: "secret \"\(name)\" may not be typed into \(origin); its domains are \(list)")
        }
    }
}

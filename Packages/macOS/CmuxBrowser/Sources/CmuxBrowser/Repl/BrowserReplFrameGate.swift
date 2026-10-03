public import WebKit

/// A frame's document as the domain policy judges it: `location.origin`
/// and `location.protocol + "//" + location.host`. `location` and its
/// members are unforgeable, so script in any content world reads WebKit's
/// own values there.
public struct BrowserReplFrameDocument: Sendable, Equatable {
    /// The document's origin (`location.origin`, `"null"` when opaque).
    public var origin: String?
    /// The document URL's scheme and host: `https://example.com:8443`, `about://`.
    public var place: String

    public init(origin: String?, place: String) {
        self.origin = origin
        self.place = place
    }

    /// The document WebKit recorded for a frame when the tree was read; a
    /// frame that navigated since shows another one.
    @MainActor
    public init(info: WKFrameInfo) {
        let securityOrigin = info.securityOrigin
        if securityOrigin.protocol.isEmpty {
            origin = "null"
        } else {
            let scheme = securityOrigin.protocol.lowercased()
            let port = securityOrigin.port
            let isDefault = port == 0 || (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
            origin = "\(scheme)://\(Self.bracketed(securityOrigin.host.lowercased()))" + (isDefault ? "" : ":\(port)")
        }
        place = Self.place(of: info.request.url)
    }

    /// A main frame's document as its URL names it.
    public init(url: URL?) {
        place = Self.place(of: url)
        let scheme = url?.scheme?.lowercased()
        origin = scheme == "http" || scheme == "https" ? place : nil
    }

    private static func place(of url: URL?) -> String {
        // A frame with no URL shows its initial empty document.
        guard let url, let scheme = url.scheme?.lowercased() else { return "about://" }
        var host = bracketed((url.host(percentEncoded: true) ?? "").lowercased())
        if let port = url.port,
           !((scheme == "https" || scheme == "wss") && port == 443),
           !((scheme == "http" || scheme == "ws") && port == 80) {
            host += ":\(port)"
        }
        return "\(scheme)://\(host)"
    }

    private static func bracketed(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }
}

extension BrowserReplDomainPolicy {
    /// Why the policy blocks a frame that shows `document`, or nil. Its
    /// origin and its URL's host must both be allowed: an `about:blank` or
    /// `blob:` document carries the origin of the page that made it.
    public func blockReason(document: BrowserReplFrameDocument) -> String? {
        guard isActive else { return nil }
        if let origin = document.origin, origin != "null", let reason = blockReason(origin + "/") {
            return reason
        }
        return blockReason(document.place + "/")
    }
}

/// Applies a REPL session's domain policy to every frame of a tab, not only
/// its main frame: a page the policy allows can embed a frame that shows a
/// page it blocks (a tab the user owns has no content rules, and a frame can
/// load before the policy is set).
///
/// Decisions come from WebKit's record of each frame (`WKFrameInfo`) and from
/// the frame's document read in the gate's content world, which agent and
/// page code cannot reach; never from anything the REPL's JavaScript sends.
/// A frame keeps its id when it navigates, so an evaluation is bound to the
/// document the gate approved: it checks `location` first and runs nothing
/// in another document.
@MainActor
public final class BrowserReplFrameGate {
    /// The session's policy; only the native session sets it.
    public var policy = BrowserReplDomainPolicy()
    private let world: WKContentWorld
    /// The document each frame last showed when the gate read it.
    private var known: [Key: BrowserReplFrameDocument] = [:]

    private struct Key: Hashable {
        let webView: ObjectIdentifier
        let frameID: String
    }

    /// - Parameter world: a content world agent and page code cannot reach.
    public init(world: WKContentWorld) {
        self.world = world
    }

    /// Why the policy blocks the document WebKit recorded for `frame` when
    /// the tree was read, or nil. The main frame without frame info is
    /// judged by the web view's URL.
    public func recordedBlockReason(of frame: BrowserReplFrame, in webView: WKWebView) -> String? {
        guard policy.isActive else { return nil }
        if let info = frame.info { return policy.blockReason(document: BrowserReplFrameDocument(info: info)) }
        return policy.blockReason(document: BrowserReplFrameDocument(url: webView.url))
    }

    /// Reads the document `frame` shows now and throws `blocked` when the
    /// policy blocks it. Returns the document, or nil without a policy.
    @discardableResult
    public func authorize(_ frame: BrowserReplFrame, in webView: WKWebView) async throws -> BrowserReplFrameDocument? {
        guard policy.isActive else { return nil }
        let document = try await read(frame, in: webView)
        if let reason = policy.blockReason(document: document) {
            throw blocked(frame, document: document, reason: reason)
        }
        known[key(frame, webView)] = document
        return document
    }

    // MARK: - Private

    private static let readSource = """
    return [location.origin, location.protocol + "//" + location.host];
    """

    private func key(_ frame: BrowserReplFrame, _ webView: WKWebView) -> Key {
        if known.count > 4_096 { known.removeAll() }
        return Key(webView: ObjectIdentifier(webView), frameID: frame.info == nil ? "main" : frame.frameID)
    }

    private func read(_ frame: BrowserReplFrame, in webView: WKWebView) async throws -> BrowserReplFrameDocument {
        let value: Any?
        do {
            value = try await webView.callAsyncJavaScript(Self.readSource, arguments: [:], in: frame.info, contentWorld: world)
        } catch {
            throw BrowserReplDriverError(code: "stale", message: "Frame \(frame.frameID) did not answer: \(error.localizedDescription)")
        }
        guard let pair = value as? [Any], pair.count == 2, let place = pair[1] as? String else {
            throw BrowserReplDriverError(code: "stale", message: "Frame \(frame.frameID) did not answer")
        }
        return BrowserReplFrameDocument(origin: pair[0] as? String, place: place)
    }

    private func blocked(_ frame: BrowserReplFrame, document: BrowserReplFrameDocument?, reason: String) -> BrowserReplDriverError {
        let shown = document.map { $0.origin.flatMap { $0 == "null" ? nil : $0 } ?? $0.place } ?? frame.url
        if frame.info == nil || frame.parentFrameID == nil {
            return BrowserReplDriverError(code: "blocked", message: "The tab shows \(shown), which the domain policy blocks: \(reason)")
        }
        return BrowserReplDriverError(code: "blocked", message: "Frame \(frame.frameID) shows \(shown), which the domain policy blocks: \(reason)")
    }
}

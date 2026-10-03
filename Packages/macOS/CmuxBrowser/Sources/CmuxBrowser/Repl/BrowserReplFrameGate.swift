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

    /// Runs `body` (a `callAsyncJavaScript` function body) in `frame` only
    /// while the frame shows a document the policy allows. The call first
    /// checks, in the frame, that the document is the one the gate approved,
    /// and returns without running `body` if the frame has navigated since;
    /// the gate then judges the new document and runs it again.
    public func callAsyncJavaScript(
        _ body: String,
        arguments: [String: Any],
        in webView: WKWebView,
        frame: BrowserReplFrame,
        contentWorld: WKContentWorld
    ) async throws -> Any? {
        guard policy.isActive else {
            return try await webView.callAsyncJavaScript(body, arguments: arguments, in: frame.info, contentWorld: contentWorld)
        }
        let key = key(frame, webView)
        var expected = known[key]
            ?? frame.info.map { BrowserReplFrameDocument(info: $0) }
            ?? BrowserReplFrameDocument(url: webView.url)
        if policy.blockReason(document: expected) != nil, let current = try await authorize(frame, in: webView) {
            expected = current
        }
        var bound = arguments
        for _ in 0..<3 {
            bound[Self.originArgument] = expected.origin ?? NSNull()
            bound[Self.placeArgument] = expected.place
            let value = try await webView.callAsyncJavaScript(
                Self.documentCheck + body,
                arguments: bound,
                in: frame.info,
                contentWorld: contentWorld
            )
            guard value as? String == Self.movedMarker else {
                known[key] = expected
                return value
            }
            guard let current = try await authorize(frame, in: webView) else { break }
            expected = current
        }
        throw BrowserReplDriverError(code: "stale", message: "Frame \(frame.frameID) kept navigating; try again once it has loaded")
    }

    /// Throws `blocked` when a pointer event at any of `points` (CSS pixels
    /// of the main frame's viewport) could reach a frame the policy blocks:
    /// the point is inside the box of the main frame's child frame that is,
    /// or holds, a blocked frame. Overlapping content is not subtracted, and
    /// a blocked frame whose box cannot be found refuses every point.
    public func checkPointer(at points: [CGPoint], in webView: WKWebView, frames: [BrowserReplFrame]) async throws {
        guard policy.isActive, !points.isEmpty else { return }
        let blockedFrames = blocked(frames, in: webView)
        guard let first = blockedFrames.first, let main = frames.first else { return }
        if first.frame.frameID == main.frameID {
            throw blocked(first.frame, document: nil, reason: first.reason)
        }
        let byID = Dictionary(frames.map { ($0.frameID, $0) }, uniquingKeysWith: { first, _ in first })
        var tops: [(top: BrowserReplFrame, blocked: BrowserReplFrame, reason: String)] = []
        for entry in blockedFrames {
            var top = entry.frame
            while let parentID = top.parentFrameID, parentID != main.frameID, let parent = byID[parentID] {
                top = parent
            }
            guard top.parentFrameID == main.frameID else {
                throw BrowserReplDriverError(code: "blocked", message: "Frame \(entry.frame.url) shows a page the domain policy blocks (\(entry.reason)) and its position is unknown, so pointer input to this tab is refused")
            }
            if !tops.contains(where: { $0.top.frameID == top.frameID }) {
                tops.append((top, entry.frame, entry.reason))
            }
        }
        let value = try await webView.callAsyncJavaScript(
            Self.boxesSource,
            arguments: ["indexes": tops.map(\.top.indexInParent)],
            in: nil,
            contentWorld: world
        )
        let boxes = value as? [Any] ?? []
        for (index, entry) in tops.enumerated() {
            guard index < boxes.count, let box = boxes[index] as? [String: Any],
                  let x = (box["x"] as? NSNumber)?.doubleValue, let y = (box["y"] as? NSNumber)?.doubleValue,
                  let width = (box["width"] as? NSNumber)?.doubleValue, let height = (box["height"] as? NSNumber)?.doubleValue else {
                throw BrowserReplDriverError(code: "blocked", message: "Frame \(entry.blocked.url) shows a page the domain policy blocks (\(entry.reason)) and its position is unknown, so pointer input to this tab is refused")
            }
            for point in points where point.x >= x && point.x <= x + width && point.y >= y && point.y <= y + height {
                throw BrowserReplDriverError(code: "blocked", message: "The point (\(Self.format(point.x)), \(Self.format(point.y))) is over frame \(entry.blocked.url), which the domain policy blocks: \(entry.reason)")
            }
        }
    }

    /// Throws `blocked` when keyboard input would reach a frame the policy
    /// blocks: the frame holds the focus (its document has it, or holds a
    /// focused element, or its parent's focused element is its frame
    /// element). A frame that cannot answer counts as focused.
    public func checkFocus(in webView: WKWebView, frames: [BrowserReplFrame]) async throws {
        guard policy.isActive else { return }
        let blockedFrames = blocked(frames, in: webView)
        guard !blockedFrames.isEmpty else { return }
        let byID = Dictionary(frames.map { ($0.frameID, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in blockedFrames {
            let refusal = BrowserReplDriverError(code: "blocked", message: "The keyboard focus is in frame \(entry.frame.url), which the domain policy blocks: \(entry.reason)")
            guard let info = entry.frame.info else { throw refusal }
            let probe: [String: Any]
            do {
                probe = try await webView.callAsyncJavaScript(Self.focusSource, arguments: [:], in: info, contentWorld: world) as? [String: Any] ?? [:]
            } catch {
                // A frame that has gone takes no input; any other failure
                // leaves its focus unknown.
                if Self.isGoneFrame(error) { continue }
                throw refusal
            }
            if probe["inner"] as? Bool == true { continue }
            if probe["focused"] as? Bool == true { throw refusal }
            guard let parentID = entry.frame.parentFrameID, let parent = byID[parentID] else { continue }
            let ownsFocus = try? await webView.callAsyncJavaScript(
                Self.ownerFocusSource,
                arguments: ["index": entry.frame.indexInParent],
                in: parent.info,
                contentWorld: world
            ) as? Bool
            if ownsFocus ?? true { throw refusal }
        }
    }

    /// Throws `blocked` when any frame of the tab shows a page the policy
    /// blocks: a screenshot or PDF would show it.
    public func checkCapture(in webView: WKWebView, frames: [BrowserReplFrame]) throws {
        guard let entry = blocked(frames, in: webView).first else { return }
        throw BrowserReplDriverError(code: "blocked", message: "The tab shows frame \(entry.frame.url), which the domain policy blocks: \(entry.reason); a capture would show it")
    }

    /// The frames whose recorded documents the policy blocks.
    public func blocked(_ frames: [BrowserReplFrame], in webView: WKWebView) -> [(frame: BrowserReplFrame, reason: String)] {
        guard policy.isActive else { return [] }
        return frames.compactMap { frame in
            recordedBlockReason(of: frame, in: webView).map { (frame, $0) }
        }
    }

    // MARK: - Private

    private static let originArgument = "__cmuxDocumentOrigin"
    private static let placeArgument = "__cmuxDocumentPlace"
    private static let movedMarker = "__cmuxDocumentMoved__"

    /// Runs first in every gated call. Only unforgeable `location` members
    /// and string operators: the content world's other globals may belong
    /// to agent code.
    private static let documentCheck = """
    if (location.origin !== \(originArgument) || location.protocol + "//" + location.host !== \(placeArgument)) return "\(movedMarker)";

    """

    private static let readSource = """
    return [location.origin, location.protocol + "//" + location.host];
    """

    private static let boxesSource = """
    const owners = new Map();
    const visit = (root) => {
      for (const el of root.querySelectorAll("iframe, frame, object")) {
        const w = el.contentWindow;
        if (w && !owners.has(w)) owners.set(w, el);
      }
      for (const el of root.querySelectorAll("*")) if (el.shadowRoot) visit(el.shadowRoot);
    };
    visit(document);
    return indexes.map((i) => {
      const target = window.frames[i];
      const el = target ? owners.get(target) : null;
      if (!el) return null;
      const r = el.getBoundingClientRect();
      return { x: r.left, y: r.top, width: r.width, height: r.height };
    });
    """

    private static let focusSource = """
    const e = document.activeElement;
    const inner = !!e && (e.tagName === "IFRAME" || e.tagName === "FRAME" || e.tagName === "OBJECT");
    return { inner, focused: !inner && (document.hasFocus() || (!!e && e !== document.body && e !== document.documentElement)) };
    """

    private static let ownerFocusSource = """
    const e = document.activeElement;
    const w = window.frames[index];
    return !!e && !!w && e.contentWindow === w;
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

    private static func isGoneFrame(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == WKErrorDomain && nsError.code == WKError.javaScriptInvalidFrameTarget.rawValue
    }

    private static func format(_ value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", Double(value))
    }
}

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
    /// How long one of the gate's own probes (a frame's document, its focus,
    /// the frame boxes) may take. WebKit does not call a script's completion
    /// when a navigation replaces the document it runs in, and a busy page
    /// answers late; past this the call is refused with `stale`.
    private let probeTimeout: Duration
    private let clock: any Clock<Duration>
    /// The document each frame last showed when the gate read it.
    private var known: [Key: BrowserReplFrameDocument] = [:]

    private struct Key: Hashable {
        let webView: ObjectIdentifier
        let frameID: String
    }

    /// - Parameters:
    ///   - world: a content world agent and page code cannot reach.
    ///   - probeTimeout: the bound on each of the gate's own probes.
    ///   - clock: measures `probeTimeout`.
    public init(world: WKContentWorld, probeTimeout: Duration = .seconds(5), clock: any Clock<Duration> = ContinuousClock()) {
        self.world = world
        self.probeTimeout = probeTimeout
        self.clock = clock
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
        let tops = try blockedTops(frames, in: webView)
        guard !tops.isEmpty else { return }
        let found = try await boxes(of: tops, in: webView, frames: frames, effects: false)
        for (entry, box) in zip(tops, found.boxes) {
            guard let box else {
                throw BrowserReplDriverError(code: "blocked", message: "Frame \(entry.blocked.url) shows a page the domain policy blocks (\(entry.reason)) and its position is unknown, so pointer input to this tab is refused")
            }
            for point in points where point.x >= box.minX && point.x <= box.maxX && point.y >= box.minY && point.y <= box.maxY {
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
            let focus: [String: Any]
            do {
                focus = try await probe(
                    Self.focusSource, arguments: [:], in: webView, frame: info,
                    what: "frame \(entry.frame.url) did not report its focus"
                ) as? [String: Any] ?? [:]
            } catch let error as BrowserReplDriverError where error.code == "stale" {
                throw error
            } catch {
                // A frame that has gone takes no input; any other failure
                // leaves its focus unknown.
                if Self.isGoneFrame(error) { continue }
                throw refusal
            }
            if focus["inner"] as? Bool == true { continue }
            if focus["focused"] as? Bool == true { throw refusal }
            guard let parentID = entry.frame.parentFrameID, let parent = byID[parentID] else { continue }
            let ownsFocus: Bool?
            do {
                ownsFocus = try await probe(
                    Self.ownerFocusSource, arguments: ["index": entry.frame.indexInParent], in: webView, frame: parent.info,
                    what: "frame \(parent.url) did not report its focus"
                ) as? Bool
            } catch let error as BrowserReplDriverError where error.code == "stale" {
                throw error
            } catch {
                ownsFocus = nil
            }
            if ownsFocus ?? true { throw refusal }
        }
    }

    /// Throws `blocked` when any frame of the tab shows a page the policy
    /// blocks: a screenshot or PDF would show it.
    public func checkCapture(in webView: WKWebView, frames: [BrowserReplFrame]) throws {
        guard let entry = blocked(frames, in: webView).first else { return }
        throw BrowserReplDriverError(code: "blocked", message: "The tab shows frame \(entry.frame.url), which the domain policy blocks: \(entry.reason); a capture would show it")
    }

    /// Runs `capture`, which returns an image of `region` (CSS pixels of the
    /// main frame's viewport, its origin at the image's top-left), and
    /// blanks in it the box of every main-frame child frame that is, or
    /// holds, a frame the policy blocks, as the tree is before and after
    /// the capture. A frame's content draws only inside its frame element's
    /// box, so the rest of the page stays as it is.
    ///
    /// Throws `blocked`, before or after the capture, when the main frame is
    /// blocked or a blocked frame's content cannot be hidden this way: its
    /// box is unknown, its frame element or an ancestor draws it elsewhere
    /// (`-webkit-box-reflect`, `filter`), or an element of the page samples
    /// what lies under it (`backdrop-filter`). The page can still move a
    /// frame and put it back within the capture.
    public func coverBlockedFrames(
        in webView: WKWebView,
        frames: @MainActor () async -> [BrowserReplFrame],
        capture: () async throws -> (image: CGImage, region: CGRect)
    ) async throws -> CGImage {
        guard policy.isActive else { return try await capture().image }
        let before = try await captureCovers(in: webView, frames: await frames())
        let (image, region) = try await capture()
        let after = try await captureCovers(in: webView, frames: await frames())
        let covers = before + after
        guard !covers.isEmpty else { return image }
        return try Self.blank(covers, in: image, region: region)
    }

    /// The boxes (CSS pixels of the main frame's viewport) a capture must
    /// blank; see ``coverBlockedFrames(in:frames:capture:)``.
    func captureCovers(in webView: WKWebView, frames: [BrowserReplFrame]) async throws -> [CGRect] {
        let tops = try blockedTops(frames, in: webView)
        guard !tops.isEmpty else { return [] }
        let found = try await boxes(of: tops, in: webView, frames: frames, effects: true)
        if found.backdrop {
            throw BrowserReplDriverError(code: "blocked", message: "The tab shows frame \(tops[0].blocked.url), which the domain policy blocks (\(tops[0].reason)), and an element of the page blurs or filters what lies under it (backdrop-filter), so a capture could show the frame")
        }
        return try zip(tops, found.boxes).map { entry, box in
            guard let box else {
                throw BrowserReplDriverError(code: "blocked", message: "The tab shows frame \(entry.blocked.url), which the domain policy blocks (\(entry.reason)); its position is unknown, so a capture could show it")
            }
            if found.escapes.contains(entry.top.frameID) {
                throw BrowserReplDriverError(code: "blocked", message: "The tab shows frame \(entry.blocked.url), which the domain policy blocks (\(entry.reason)), and the page draws it outside its box (-webkit-box-reflect or filter), so a capture could show it")
            }
            return box
        }
    }

    /// `image` (of `region`) with `covers` filled in gray.
    static func blank(_ covers: [CGRect], in image: CGImage, region: CGRect) throws -> CGImage {
        let width = image.width
        let height = image.height
        guard region.width > 0, region.height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw BrowserReplDriverError(code: "invalid", message: "Could not hide the blocked frames in the capture")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let scaleX = CGFloat(width) / region.width
        let scaleY = CGFloat(height) / region.height
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        for cover in covers {
            // Whole pixels, rounded outward, so no edge of the frame shows.
            let x = floor((cover.minX - region.minX) * scaleX)
            let top = floor((cover.minY - region.minY) * scaleY)
            let right = ceil((cover.maxX - region.minX) * scaleX)
            let bottom = ceil((cover.maxY - region.minY) * scaleY)
            context.fill(CGRect(x: x, y: CGFloat(height) - bottom, width: right - x, height: bottom - top))
        }
        guard let result = context.makeImage() else {
            throw BrowserReplDriverError(code: "invalid", message: "Could not hide the blocked frames in the capture")
        }
        return result
    }

    /// Throws `blocked` when the policy blocks the frame a file chooser
    /// opened from: as WebKit recorded it when the chooser opened, and the
    /// document it shows now when it is still in `frames`. Other frames of
    /// the tab do not matter; the files go only to that frame's input.
    public func checkFileChooser(frame info: WKFrameInfo, in webView: WKWebView, frames: [BrowserReplFrame]) async throws {
        guard policy.isActive else { return }
        let refusal = { (shown: String, reason: String) in
            BrowserReplDriverError(code: "blocked", message: "The file chooser opened in a frame showing \(shown), which the domain policy blocks: \(reason); it may only be cancelled")
        }
        let recorded = BrowserReplFrameDocument(info: info)
        if let reason = policy.blockReason(document: recorded) {
            throw refusal(recorded.origin ?? recorded.place, reason)
        }
        let frame: BrowserReplFrame?
        if info.isMainFrame {
            frame = frames.first
        } else {
            let id = BrowserReplFrame.frameID(of: info)
            frame = id.flatMap { id in frames.first { $0.frameID == id } }
        }
        guard let frame else { return }
        try await authorize(frame, in: webView)
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

    /// The boxes of the main frame's child frames at `indexes` (their
    /// indexes in WebKit's frame tree). `window.frames` holds only the
    /// frames of the document's own tree, not those in shadow trees, and
    /// WebKit orders both lists the same way; so the indexes match only
    /// when the main frame has no frame in a shadow tree (`window.frames`
    /// is as long as the tree's `childCount`). Otherwise every box is
    /// unknown. With `effects`, also whether a frame element or an
    /// ancestor draws it outside its box, and whether any element samples
    /// what lies under it. Agent code shares no state with this world, and
    /// `window.frames`, `contentWindow` and computed styles come from the
    /// engine.
    private static let boxesSource = """
    if (window.frames.length !== childCount) return { boxes: indexes.map(() => null), escapes: [], backdrop: false };
    const owners = new Map();
    let backdrop = false;
    const styleOf = (el) => getComputedStyle(el);
    const drawsElsewhere = (cs) => (cs.getPropertyValue("filter") || "none") !== "none"
      || (cs.getPropertyValue("-webkit-box-reflect") || "none") !== "none";
    const visit = (root) => {
      for (const el of root.querySelectorAll("iframe, frame, object, embed")) {
        const w = el.contentWindow;
        if (w && !owners.has(w)) owners.set(w, el);
      }
      for (const el of root.querySelectorAll("*")) {
        if (effects && !backdrop) {
          const cs = styleOf(el);
          const value = cs.getPropertyValue("backdrop-filter") || cs.getPropertyValue("-webkit-backdrop-filter") || "none";
          if (value !== "none") backdrop = true;
        }
        if (el.shadowRoot) visit(el.shadowRoot);
      }
    };
    visit(document);
    const escapes = [];
    const boxes = indexes.map((i, n) => {
      const target = window.frames[i];
      const el = target ? owners.get(target) : null;
      if (!el) return null;
      if (effects) {
        for (let node = el; node; node = node.parentNode || node.host) {
          if (node.nodeType === 1 && drawsElsewhere(styleOf(node))) { escapes.push(n); break; }
        }
      }
      const r = el.getBoundingClientRect();
      return { x: r.left, y: r.top, width: r.width, height: r.height };
    });
    return { boxes, escapes, backdrop };
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

    private struct BlockedTop {
        /// The main frame's child frame that is, or holds, `blocked`.
        let top: BrowserReplFrame
        let blocked: BrowserReplFrame
        let reason: String
    }

    /// The main frame's child frames that are or hold a blocked frame, one
    /// per child. Throws `blocked` when the main frame is blocked, or a
    /// blocked frame's place in the tree is unknown.
    private func blockedTops(_ frames: [BrowserReplFrame], in webView: WKWebView) throws -> [BlockedTop] {
        let blockedFrames = blocked(frames, in: webView)
        guard let first = blockedFrames.first, let main = frames.first else { return [] }
        if first.frame.frameID == main.frameID {
            throw blocked(first.frame, document: nil, reason: first.reason)
        }
        let byID = Dictionary(frames.map { ($0.frameID, $0) }, uniquingKeysWith: { first, _ in first })
        var tops: [BlockedTop] = []
        for entry in blockedFrames {
            var top = entry.frame
            while let parentID = top.parentFrameID, parentID != main.frameID, let parent = byID[parentID] {
                top = parent
            }
            guard top.parentFrameID == main.frameID else {
                throw BrowserReplDriverError(code: "blocked", message: "Frame \(entry.frame.url) shows a page the domain policy blocks (\(entry.reason)) and its position is unknown, so input and captures of this tab are refused")
            }
            if !tops.contains(where: { $0.top.frameID == top.frameID }) {
                tops.append(BlockedTop(top: top, blocked: entry.frame, reason: entry.reason))
            }
        }
        return tops
    }

    /// The boxes (CSS pixels of the main frame's viewport) of `tops`, in
    /// order, `nil` where unknown; see ``boxesSource``.
    private func boxes(
        of tops: [BlockedTop],
        in webView: WKWebView,
        frames: [BrowserReplFrame],
        effects: Bool
    ) async throws -> (boxes: [CGRect?], escapes: Set<String>, backdrop: Bool) {
        let mainID = frames.first?.frameID
        let childCount = frames.filter { $0.parentFrameID != nil && $0.parentFrameID == mainID }.count
        let value = try await probe(
            Self.boxesSource,
            arguments: ["indexes": tops.map(\.top.indexInParent), "childCount": childCount, "effects": effects],
            in: webView,
            frame: nil,
            what: "the page did not report its frames' positions"
        ) as? [String: Any] ?? [:]
        let list = value["boxes"] as? [Any] ?? []
        let boxes: [CGRect?] = tops.indices.map { index in
            guard index < list.count, let box = list[index] as? [String: Any],
                  let x = (box["x"] as? NSNumber)?.doubleValue, let y = (box["y"] as? NSNumber)?.doubleValue,
                  let width = (box["width"] as? NSNumber)?.doubleValue, let height = (box["height"] as? NSNumber)?.doubleValue,
                  x.isFinite, y.isFinite, width.isFinite, height.isFinite else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }
        // An effect check that did not answer counts as drawing elsewhere.
        let escapeIndexes = (value["escapes"] as? [NSNumber])?.map(\.intValue) ?? (effects ? Array(tops.indices) : [])
        let escapes = Set(escapeIndexes.compactMap { $0 < tops.count ? tops[$0].top.frameID : nil })
        let backdrop = (value["backdrop"] as? Bool) ?? effects
        return (boxes, escapes, backdrop)
    }

    private func key(_ frame: BrowserReplFrame, _ webView: WKWebView) -> Key {
        if known.count > 4_096 { known.removeAll() }
        return Key(webView: ObjectIdentifier(webView), frameID: frame.info == nil ? "main" : frame.frameID)
    }

    private func read(_ frame: BrowserReplFrame, in webView: WKWebView) async throws -> BrowserReplFrameDocument {
        let value: Any?
        do {
            value = try await probe(Self.readSource, arguments: [:], in: webView, frame: frame.info, what: "frame \(frame.frameID) did not answer")
        } catch let error as BrowserReplDriverError {
            throw error
        } catch {
            throw BrowserReplDriverError(code: "stale", message: "Frame \(frame.frameID) did not answer: \(error.localizedDescription)")
        }
        guard let pair = value as? [Any], pair.count == 2, let place = pair[1] as? String else {
            throw BrowserReplDriverError(code: "stale", message: "Frame \(frame.frameID) did not answer")
        }
        return BrowserReplFrameDocument(origin: pair[0] as? String, place: place)
    }

    /// Runs one of the gate's own scripts in its world, failing with
    /// `stale` when it has not answered within ``probeTimeout``. The
    /// script itself cannot be cancelled; a late answer is dropped.
    private func probe(
        _ source: String,
        arguments: [String: Any],
        in webView: WKWebView,
        frame: WKFrameInfo?,
        what: String
    ) async throws -> Any? {
        let race = ProbeRace()
        let world = self.world
        Task { @MainActor in
            do {
                race.finish(.success(BrowserReplProbeValue(value: try await webView.callAsyncJavaScript(source, arguments: arguments, in: frame, contentWorld: world))))
            } catch {
                race.finish(.failure(error))
            }
        }
        let clock = self.clock
        let timeout = probeTimeout
        let message = "\(what) within \(timeout.components.seconds) s (it may have navigated or be busy); try again"
        let deadline = Task { @MainActor in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            race.finish(.failure(BrowserReplDriverError(code: "stale", message: message.prefix(1).uppercased() + message.dropFirst())))
        }
        defer { deadline.cancel() }
        return try await race.value().value
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

/// A probe's answer, carried between main-actor tasks.
private struct BrowserReplProbeValue: @unchecked Sendable {
    let value: Any?
}

/// First answer wins: the probe's or the timeout's.
@MainActor
private final class ProbeRace {
    private var result: Result<BrowserReplProbeValue, any Error>?
    private var continuation: CheckedContinuation<BrowserReplProbeValue, any Error>?

    func finish(_ value: Result<BrowserReplProbeValue, any Error>) {
        guard result == nil else { return }
        result = value
        if let continuation {
            self.continuation = nil
            continuation.resume(with: value)
        }
    }

    func value() async throws -> BrowserReplProbeValue {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation in
            if let result {
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
            }
        }
    }
}

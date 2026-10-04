public import WebKit

extension WKFrameInfo {
    /// The origin (`scheme://host[:port]`) of the frame, from WebKit's own
    /// record of it, never from page script.
    public var browserReplOrigin: String? {
        let origin = securityOrigin
        guard !origin.protocol.isEmpty, !origin.host.isEmpty else { return nil }
        let isDefault = origin.port == 0
            || (origin.protocol == "https" && origin.port == 443)
            || (origin.protocol == "http" && origin.port == 80)
        return isDefault ? "\(origin.protocol)://\(origin.host)" : "\(origin.protocol)://\(origin.host):\(origin.port)"
    }
}

extension WKContentWorld {
    /// A named content world that sees closed shadow roots
    /// (`_WKContentWorldConfiguration.allowAccessToClosedShadowRoots`, the
    /// switch WebKit gives web extension worlds): in it `element.shadowRoot`
    /// returns a closed root too. Page scripts in other worlds still see
    /// `null`. Without the SPI it is a plain named world and closed roots
    /// stay hidden.
    @MainActor
    public static func browserReplWorld(seeingClosedShadowRoots name: String) -> WKContentWorld {
        guard let configurationClass = NSClassFromString("_WKContentWorldConfiguration") as? NSObject.Type else {
            return .world(name: name)
        }
        let configuration = configurationClass.init()
        let setName = NSSelectorFromString("setName:")
        let setClosed = NSSelectorFromString("setAllowAccessToClosedShadowRoots:")
        let factory = NSSelectorFromString("_worldWithConfiguration:")
        guard configuration.responds(to: setName), configuration.responds(to: setClosed),
              (WKContentWorld.self as AnyObject).responds(to: factory) else {
            return .world(name: name)
        }
        configuration.setValue(name, forKey: "name")
        configuration.setValue(true, forKey: "allowAccessToClosedShadowRoots")
        return (WKContentWorld.self as AnyObject).perform(factory, with: configuration)?
            .takeUnretainedValue() as? WKContentWorld ?? .world(name: name)
    }
}

/// Hides secret values in one screenshot or PDF of a tab, and refuses a
/// capture that could show a page the domain policy blocks.
///
/// The session sends a capture its `secretMasks` (`[{ value, domains }]`).
/// In every frame whose document's origin is on a secret's domains (the
/// only frames it can be typed into), fields and text holding a value
/// render as password dots (`-webkit-text-security`) for the length of the
/// capture. Other frames never get a value. The scan runs in a content
/// world of its own, which page scripts and agent code cannot reach, and
/// which sees closed shadow roots as the agent's world does, so a value the
/// agent can read there is masked there too.
///
/// A frame keeps its id when it navigates, so the frame list WebKit gives
/// can name a document the frame no longer shows. The mask therefore goes
/// by documents, not by that list: before the capture it marks every
/// frame's document with the capture's token and reads its origin there,
/// picks the values from that origin, and masks only in a document that
/// still holds the mark. After the capture every frame must still show a
/// marked document, so none showed another page meanwhile (a navigation
/// gives the frame a new global object, without the mark).
///
/// The domain policy judges the document each frame shows when it is
/// marked, the one the capture shows. A blocked main frame refuses the
/// capture. A blocked child frame refuses a capture that cannot hide it (a
/// PDF, ``BlockedChildFrames/refuse``); a screenshot is handed those
/// frames and blanks them (``BlockedChildFrames/handToCapture``).
///
/// It fails closed. The capture is refused when a frame does not answer
/// (`stale` when a script takes over the probe's bound, 5 s by default),
/// shows a page the domain policy blocks (as above), shows a document it
/// did not show when the capture was prepared, or when the mask step fails, or
/// when, after the capture, a scan finds an element holding a value that
/// does not render masked (the page dropped the mask or added the value
/// while the capture ran). The page owns its DOM, so a value it changes
/// and restores within the capture, or draws in a form the scan does not
/// read (a canvas, an image, split across elements, transformed), is not
/// caught.
///
/// Each capture records the elements it masked under its own token and
/// restores only those, so concurrent captures do not unmask each other.
@MainActor
public struct BrowserReplCaptureMask {
    struct Mask {
        let value: String
        let domains: [BrowserReplDomainPattern]
    }

    /// The content world the mask scan runs in.
    static let world = WKContentWorld.browserReplWorld(seeingClosedShadowRoots: "cmux-capture-mask")

    /// What a capture does with a child frame whose document the domain
    /// policy blocks.
    public enum BlockedChildFrames: Sendable {
        /// The capture cannot hide a frame (a PDF, laid out for print):
        /// such a frame refuses it.
        case refuse
        /// The capture blanks blocked frames itself (a screenshot): it is
        /// handed those frames and must blank each or refuse.
        case handToCapture
    }

    let masks: [Mask]
    let policy: BrowserReplDomainPolicy
    let blockedChildFrames: BlockedChildFrames
    /// Bounds each of the mask's scripts: WebKit drops a script's
    /// completion when a navigation replaces its document.
    let probe: BrowserReplScriptProbe
    private let token = UUID().uuidString

    /// - Parameters:
    ///   - secretMasks: The `secretMasks` the session added to the call.
    ///   - policy: The session's domain policy; a capture while the main
    ///     frame shows a page it blocks is refused.
    ///   - blockedChildFrames: What a child frame that shows a page the
    ///     policy blocks does to the capture.
    ///   - probe: Bounds each of the mask's scripts; one that does not
    ///     answer in time refuses the capture with `stale`.
    public init(
        secretMasks: [[String: Any]],
        policy: BrowserReplDomainPolicy = BrowserReplDomainPolicy(),
        blockedChildFrames: BlockedChildFrames = .refuse,
        probe: BrowserReplScriptProbe = BrowserReplScriptProbe()
    ) {
        self.policy = policy
        self.blockedChildFrames = blockedChildFrames
        self.probe = probe
        masks = secretMasks.compactMap { mask in
            guard let value = mask["value"] as? String, !value.isEmpty,
                  let domains = mask["domains"] as? [[String: Any]] else { return nil }
            return Mask(value: value, domains: domains.compactMap(BrowserReplDomainPattern.from(json:)))
        }
    }

    public var isEmpty: Bool { masks.isEmpty }

    /// Runs `capture` with the values masked in `webView`, or throws
    /// without returning the capture when masking fails or a frame shows a
    /// page the policy blocks.
    ///
    /// - Parameters:
    ///   - frames: Reads the tab's frames as they are now; `nil` stands for
    ///     the main frame when WebKit gives no frame info for it.
    ///   - capture: Takes the capture. With
    ///     ``BlockedChildFrames/handToCapture`` it gets the child frames
    ///     (`BrowserReplFrame.frameID` to the policy's reason) whose marked
    ///     document the policy blocks, and must blank each or throw; with
    ///     ``BlockedChildFrames/refuse`` that is always empty.
    public func run<T>(
        in webView: WKWebView,
        frames: () async -> [WKFrameInfo?],
        _ capture: (_ blockedChildFrames: [String: String]) async throws -> T
    ) async throws -> T {
        guard !isEmpty || policy.isActive else { return try await capture([:]) }
        var marked: [WKFrameInfo?] = []
        var blockedChildren: [String: String] = [:]
        do {
            for frame in await frames() {
                marked.append(frame)
                let document = try await mark(frame, in: webView)
                // Judged on the document the mark step marked, the one the
                // capture shows (the after-capture check refuses another).
                if let reason = policy.blockReason(document: document.policyDocument) {
                    let isMain = frame?.isMainFrame ?? true
                    guard !isMain, blockedChildFrames == .handToCapture,
                          let id = frame.flatMap(BrowserReplFrame.frameID(of:)) else {
                        throw BrowserReplDriverError(
                            code: "blocked",
                            message: "The tab shows frame \(document.shown), which the domain policy blocks: \(reason); a capture would show it"
                        )
                    }
                    blockedChildren[id] = reason
                }
                let values = values(forOrigin: document.origin)
                if !values.isEmpty {
                    try await step(frame, mode: "on", values: values, shown: document.shown, in: webView)
                }
            }
        } catch {
            await unmark(marked, in: webView)
            throw error
        }
        let value: T
        do {
            value = try await capture(blockedChildren)
        } catch {
            await unmark(marked, in: webView)
            throw error
        }
        do {
            for frame in await frames() {
                try await step(frame, mode: "verify", values: [], shown: nil, in: webView)
            }
        } catch {
            await unmark(marked, in: webView)
            throw error
        }
        await unmark(marked, in: webView)
        return value
    }

    /// ``run(in:frames:_:)`` for a capture that is never handed blocked
    /// child frames (with ``BlockedChildFrames/refuse``, any refuses it).
    public func run<T>(
        in webView: WKWebView,
        frames: () async -> [WKFrameInfo?],
        _ capture: () async throws -> T
    ) async throws -> T {
        try await run(in: webView, frames: frames) { (_: [String: String]) in try await capture() }
    }

    /// The values to mask in a frame with `origin`.
    func values(forOrigin origin: String) -> [String] {
        masks.filter { $0.domains.contains { $0.matches(origin: origin, secure: true) } }.map(\.value)
    }

    /// A frame's document as the mark step read it, in the mask's world.
    private struct MarkedDocument {
        /// The document's origin (`self.origin`; `"null"` when opaque), the
        /// one secrets are typed by.
        let origin: String
        /// `location.origin` and the URL's scheme and host, as the domain
        /// policy judges frames (`BrowserReplFrameDocument`).
        let policyDocument: BrowserReplFrameDocument

        var shown: String { origin == "null" ? policyDocument.place : origin }
    }

    /// Marks the document `frame` shows now with this capture's token and
    /// reads its origin there.
    private func mark(_ frame: WKFrameInfo?, in webView: WKWebView) async throws -> MarkedDocument {
        let reply: Any?
        do {
            reply = try await probe.call(
                Self.maskSource,
                arguments: ["values": [String](), "mode": "mark", "token": token],
                in: webView,
                frame: frame,
                contentWorld: Self.world,
                what: "the capture was refused: a frame did not answer"
            )
        } catch let error as BrowserReplDriverError {
            throw error
        } catch {
            throw BrowserReplDriverError(
                code: "invalid",
                message: "the capture was refused: a frame did not answer (\(error.localizedDescription)); try again"
            )
        }
        guard let document = reply as? [String: Any], let origin = document["origin"] as? String,
              let place = document["place"] as? String else {
            throw BrowserReplDriverError(code: "invalid", message: "the capture was refused: a frame did not answer; try again")
        }
        return MarkedDocument(
            origin: origin,
            policyDocument: BrowserReplFrameDocument(origin: document["locationOrigin"] as? String, place: place)
                .withMakers(frame: frame, in: webView)
        )
    }

    /// Masks (`on`) or checks (`verify`) one frame, in the document the
    /// mark step marked only; throws when it shows another document, the
    /// step fails, or an element holding a value renders unmasked. `verify`
    /// uses the values `on` left with the mark.
    private func step(_ frame: WKFrameInfo?, mode: String, values: [String], shown: String?, in webView: WKWebView) async throws {
        let place = shown ?? "a frame"
        let reply: Any?
        do {
            reply = try await probe.call(
                Self.maskSource,
                arguments: ["values": values, "mode": mode, "token": token],
                in: webView,
                frame: frame,
                contentWorld: Self.world,
                what: "the capture was refused: \(place) did not answer"
            )
        } catch let error as BrowserReplDriverError {
            throw error
        } catch {
            throw BrowserReplDriverError(
                code: "invalid",
                message: "the capture was refused: secrets could not be masked in \(place) (\(error.localizedDescription)); try again"
            )
        }
        if reply as? String == Self.movedMarker {
            throw BrowserReplDriverError(
                code: "invalid",
                message: "the capture was refused: a frame showed another page while it was taken; try again"
            )
        }
        guard let count = reply as? NSNumber, count.intValue == 0 else {
            throw BrowserReplDriverError(
                code: "invalid",
                message: mode == "verify"
                    ? "the capture was refused: the page in \(place) showed a secret unmasked while it was taken; try again"
                    : "the capture was refused: a secret in \(place) could not be masked"
            )
        }
    }

    /// Restores what this capture masked and removes its mark.
    private func unmark(_ frames: [WKFrameInfo?], in webView: WKWebView) async {
        for frame in frames {
            // A frame that is gone holds nothing to restore, and one that
            // does not answer in time is left to restore when it runs.
            _ = try? await probe.call(
                Self.maskSource,
                arguments: ["values": [String](), "mode": "off", "token": token],
                in: webView,
                frame: frame,
                contentWorld: Self.world,
                what: "a frame did not answer"
            )
        }
    }

    private static let movedMarker = "__cmuxCaptureDocumentMoved__"

    /// `mode` is `mark` (mark this document for `token` and return its
    /// origin), `on` (mask the elements holding `values` under `token`),
    /// `off` (restore what `token` masked and drop the mark) or `verify`.
    /// `on` and `verify` return how many elements holding a value render
    /// unmasked, or the moved marker when the document holds no mark for
    /// `token` (another document than the one marked). The state lives in
    /// the world's global object, which belongs to one document.
    private static let maskSource = """
    const state = globalThis.__cmuxSecretMasks || (globalThis.__cmuxSecretMasks = { counts: new Map(), captures: new Map(), marks: new Map() });
    const prop = "-webkit-text-security";
    if (mode === "mark") {
      state.marks.set(token, []);
      return { origin: String(self.origin), locationOrigin: location.origin, place: location.protocol + "//" + location.host };
    }
    if (mode === "off") {
      state.marks.delete(token);
      const masked = state.captures.get(token) || [];
      state.captures.delete(token);
      for (const el of masked) {
        const entry = state.counts.get(el);
        if (!entry || --entry.count > 0) continue;
        state.counts.delete(el);
        if (entry.value) el.style.setProperty(prop, entry.value, entry.priority);
        else el.style.removeProperty(prop);
      }
      return 0;
    }
    if (!state.marks.has(token)) return "\(movedMarker)";
    if (mode === "on") state.marks.set(token, values);
    else values = state.marks.get(token);
    const hits = new Set();
    const has = (t) => typeof t === "string" && values.some((v) => t.includes(v));
    const visit = (root) => {
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
      for (let n = walker.currentNode; n; n = walker.nextNode()) {
        if (n.nodeType === 3) {
          // A shadow root's own text renders in its host.
          const owner = n.parentElement || (n.parentNode && n.parentNode.host) || null;
          if (owner && has(n.data)) hits.add(owner);
          continue;
        }
        if ((n instanceof HTMLInputElement && n.type !== "password") || n instanceof HTMLTextAreaElement) {
          if (has(n.value)) hits.add(n);
        }
        if (n.shadowRoot) visit(n.shadowRoot);
      }
    };
    visit(document.documentElement || document);
    const shows = (el) => getComputedStyle(el).getPropertyValue(prop) === "none";
    if (mode === "on") {
      // An element without inline style (one of another namespace) is
      // masked through its nearest styled ancestor; the property inherits.
      const styled = (el) => {
        for (let n = el; n; n = n.parentElement || (n.parentNode && n.parentNode.host) || null) {
          if (n.style instanceof CSSStyleDeclaration) return n;
        }
        return null;
      };
      const masked = state.captures.get(token) || new Set();
      state.captures.set(token, masked);
      for (const hit of hits) {
        const el = styled(hit);
        if (!el || masked.has(el)) continue;
        masked.add(el);
        const entry = state.counts.get(el);
        if (entry) entry.count++;
        else {
          state.counts.set(el, { count: 1, value: el.style.getPropertyValue(prop), priority: el.style.getPropertyPriority(prop) });
          el.style.setProperty(prop, "disc", "important");
        }
      }
    }
    let unmasked = 0;
    for (const el of hits) if (shows(el)) unmasked++;
    return unmasked;
    """
}

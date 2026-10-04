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

/// Hides secret values in one screenshot or PDF of a tab.
///
/// The session sends a capture its `secretMasks` (`[{ value, domains }]`).
/// In every frame whose origin is on a secret's domains (the only frames it
/// can be typed into), fields and text holding a value render as password
/// dots (`-webkit-text-security`) for the length of the capture. Other
/// frames never get a value. The scan runs in a content world of its own,
/// which page scripts and agent code cannot reach, and which sees closed
/// shadow roots as the agent's world does, so a value the agent can read
/// there is masked there too.
///
/// It fails closed. The capture is refused when the mask step fails in any
/// of those frames, or when, after the capture, a fresh scan of the tab's
/// frames finds an element holding a value that does not render masked
/// (the page dropped the mask or added the value while the capture ran).
/// The page owns its DOM, so a value it changes and restores within the
/// capture, or draws in a form the scan does not read (a canvas, an image,
/// split across elements, transformed), is not caught.
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

    let masks: [Mask]
    let policy: BrowserReplDomainPolicy
    private let token = UUID().uuidString

    /// - Parameters:
    ///   - secretMasks: The `secretMasks` the session added to the call.
    ///   - policy: The session's domain policy.
    public init(secretMasks: [[String: Any]], policy: BrowserReplDomainPolicy = BrowserReplDomainPolicy()) {
        self.policy = policy
        masks = secretMasks.compactMap { mask in
            guard let value = mask["value"] as? String, !value.isEmpty,
                  let domains = mask["domains"] as? [[String: Any]] else { return nil }
            return Mask(value: value, domains: domains.compactMap(BrowserReplDomainPattern.from(json:)))
        }
    }

    public var isEmpty: Bool { masks.isEmpty }

    /// Runs `capture` with the values masked in `webView`, or throws
    /// `invalid` without returning the capture when masking fails.
    ///
    /// - Parameters:
    ///   - frames: Reads the tab's frames as they are now; `nil` stands for
    ///     the main frame when WebKit gives no frame info for it.
    public func run<T>(
        in webView: WKWebView,
        frames: () async -> [WKFrameInfo?],
        _ capture: () async throws -> T
    ) async throws -> T {
        guard !isEmpty else { return try await capture() }
        var masked: [(frame: WKFrameInfo?, values: [String])] = []
        do {
            for target in targets(await frames(), in: webView) {
                masked.append(target)
                try await mask(target, mode: "on", in: webView)
            }
        } catch {
            await unmask(masked, in: webView)
            throw error
        }
        let value: T
        do {
            value = try await capture()
        } catch {
            await unmask(masked, in: webView)
            throw error
        }
        do {
            for target in targets(await frames(), in: webView) {
                try await mask(target, mode: "verify", in: webView)
            }
        } catch {
            await unmask(masked, in: webView)
            throw error
        }
        await unmask(masked, in: webView)
        return value
    }

    /// The values to mask in a frame with `origin`.
    func values(forOrigin origin: String) -> [String] {
        masks.filter { $0.domains.contains { $0.matches(origin: origin, secure: true) } }.map(\.value)
    }

    /// The frames on a secret's domains, with the values each may show.
    private func targets(_ frames: [WKFrameInfo?], in webView: WKWebView) -> [(frame: WKFrameInfo?, values: [String])] {
        frames.compactMap { frame in
            guard let origin = origin(of: frame, in: webView) else { return nil }
            let values = values(forOrigin: origin)
            return values.isEmpty ? nil : (frame, values)
        }
    }

    private func origin(of info: WKFrameInfo?, in webView: WKWebView) -> String? {
        if let info { return info.browserReplOrigin }
        guard let url = webView.url, let scheme = url.scheme, let host = url.host, !host.isEmpty else { return nil }
        let isDefault = url.port == nil || (scheme == "https" && url.port == 443) || (scheme == "http" && url.port == 80)
        return isDefault ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(url.port ?? 0)"
    }

    /// Masks (`on`) or checks (`verify`) one frame; throws when the step
    /// fails or an element holding a value renders unmasked.
    private func mask(_ target: (frame: WKFrameInfo?, values: [String]), mode: String, in webView: WKWebView) async throws {
        let place = origin(of: target.frame, in: webView) ?? "a frame"
        let unmasked: Any?
        do {
            unmasked = try await webView.callAsyncJavaScript(
                Self.maskSource,
                arguments: ["values": target.values, "mode": mode, "token": token],
                in: target.frame,
                contentWorld: Self.world
            )
        } catch {
            throw BrowserReplDriverError(
                code: "invalid",
                message: "the capture was refused: secrets could not be masked in \(place) (\(error.localizedDescription)); try again"
            )
        }
        guard let count = unmasked as? NSNumber, count.intValue == 0 else {
            throw BrowserReplDriverError(
                code: "invalid",
                message: mode == "verify"
                    ? "the capture was refused: the page in \(place) showed a secret unmasked while it was taken; try again"
                    : "the capture was refused: a secret in \(place) could not be masked"
            )
        }
    }

    private func unmask(_ targets: [(frame: WKFrameInfo?, values: [String])], in webView: WKWebView) async {
        for target in targets {
            // A frame that is gone holds nothing to restore.
            _ = try? await webView.callAsyncJavaScript(
                Self.maskSource,
                arguments: ["values": [String](), "mode": "off", "token": token],
                in: target.frame,
                contentWorld: Self.world
            )
        }
    }

    /// `mode` is `on` (mask the elements holding `values` under `token`),
    /// `off` (restore what `token` masked) or `verify`. `on` and `verify`
    /// return how many elements holding a value render unmasked.
    private static let maskSource = """
    const state = globalThis.__cmuxSecretMasks || (globalThis.__cmuxSecretMasks = { counts: new Map(), captures: new Map() });
    const prop = "-webkit-text-security";
    if (mode === "off") {
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

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

/// Hides secret values in one screenshot or PDF of a tab.
///
/// The session sends a capture its `secretMasks` (`[{ value, domains }]`).
/// In every frame whose origin is on a secret's domains (the only frames it
/// can be typed into), fields and text holding a value render as password
/// dots for the length of the capture. Other frames never get a value. The
/// scan runs in a content world of its own, which page scripts and agent
/// code cannot reach. Each element keeps a count, so concurrent captures do
/// not unmask each other.
@MainActor
public struct BrowserReplCaptureMask {
    struct Mask {
        let value: String
        let domains: [BrowserReplDomainPattern]
    }

    /// The content world the mask scan runs in.
    static let world = WKContentWorld.world(name: "cmux-capture-mask")

    let masks: [Mask]

    /// - Parameter secretMasks: The `secretMasks` the session added to the call.
    public init(secretMasks: [[String: Any]]) {
        masks = secretMasks.compactMap { mask in
            guard let value = mask["value"] as? String, !value.isEmpty,
                  let domains = mask["domains"] as? [[String: Any]] else { return nil }
            return Mask(value: value, domains: domains.compactMap(BrowserReplDomainPattern.from(json:)))
        }
    }

    public var isEmpty: Bool { masks.isEmpty }

    /// Runs `capture` with the values masked in `webView`.
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
        let targets = await frames()
        await set(on: true, webView: webView, frames: targets)
        do {
            let value = try await capture()
            await set(on: false, webView: webView, frames: targets)
            return value
        } catch {
            await set(on: false, webView: webView, frames: targets)
            throw error
        }
    }

    /// The values to mask in a frame with `origin`.
    func values(forOrigin origin: String) -> [String] {
        masks.filter { $0.domains.contains { $0.matches(origin: origin, secure: true) } }.map(\.value)
    }

    private func origin(of info: WKFrameInfo?, in webView: WKWebView) -> String? {
        if let info { return info.browserReplOrigin }
        guard let url = webView.url, let scheme = url.scheme, let host = url.host, !host.isEmpty else { return nil }
        let isDefault = url.port == nil || (scheme == "https" && url.port == 443) || (scheme == "http" && url.port == 80)
        return isDefault ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(url.port ?? 0)"
    }

    private func set(on: Bool, webView: WKWebView, frames: [WKFrameInfo?]) async {
        for info in frames {
            guard let info, let origin = origin(of: info, in: webView) else { continue }
            let values = values(forOrigin: origin)
            guard !values.isEmpty else { continue }
            _ = try? await webView.callAsyncJavaScript(
                Self.maskSource, arguments: ["values": values, "on": on], in: info, contentWorld: Self.world
            )
        }
    }

    private static let maskSource = """
    const counts = globalThis.__cmuxSecretMasks || (globalThis.__cmuxSecretMasks = new Map());
    const prop = "-webkit-text-security";
    if (!on) {
      for (const [el, entry] of [...counts]) {
        if (--entry.count > 0) continue;
        counts.delete(el);
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
          if (n.parentElement && has(n.data)) hits.add(n.parentElement);
          continue;
        }
        if ((n instanceof HTMLInputElement && n.type !== "password") || n instanceof HTMLTextAreaElement) {
          if (has(n.value)) hits.add(n);
        }
        if (n.shadowRoot) visit(n.shadowRoot);
      }
    };
    visit(document.documentElement || document);
    for (const el of hits) {
      const entry = counts.get(el);
      if (entry) entry.count++;
      else {
        counts.set(el, { count: 1, value: el.style.getPropertyValue(prop), priority: el.style.getPropertyPriority(prop) });
        el.style.setProperty(prop, "disc", "important");
      }
    }
    return hits.size;
    """
}

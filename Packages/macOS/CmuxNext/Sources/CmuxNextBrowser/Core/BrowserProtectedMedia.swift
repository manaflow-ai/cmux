public import Foundation

/// Protected (DRM) media a Chromium page asked for and could not get, and whether its tab reopens in
/// WebKit.
///
/// cmux's Chromium has no working Widevine CDM (the component never installs: CEF does not
/// register `DIR_COMPONENT_USER`), no H.264/AAC (`proprietary_codecs` is off) and no VMP signature,
/// so `navigator.requestMediaKeySystemAccess("com.widevine.alpha", ...)` is refused and Spotify,
/// Netflix and the like show "playback of protected content is not enabled". WebKit plays them
/// with FairPlay. ``probeScript`` notices the refusal in the page; the tab then reopens in WebKit at
/// the same address, once (``reopensInWebKit(engineIsChromium:enginePinned:alreadyReopened:)``).
public nonisolated struct BrowserProtectedMedia: Sendable, Hashable {
    /// The key system the page asked for (`com.widevine.alpha`).
    public let keySystem: String

    /// - Parameter keySystem: The key system the page asked for.
    public init(keySystem: String) {
        self.keySystem = keySystem
    }

    /// Whether this is a protected key system cmux's Chromium cannot serve: Widevine, PlayReady or
    /// FairPlay. Clear Key (`org.w3.clearkey`) is not: Chromium has it, and a refusal there is the
    /// page's own configuration.
    public var needsAnotherEngine: Bool {
        false
    }

    /// Whether the tab reopens in WebKit at the same address.
    ///
    /// - Parameters:
    ///   - engineIsChromium: The tab is a Chromium tab (a WebKit tab never reopens).
    ///   - enginePinned: Someone asked for this tab's engine (`--engine chromium`, a site rule for
    ///     Chromium): their choice wins.
    ///   - alreadyReopened: The tab reopened once already.
    /// - Returns: True to reopen it in WebKit.
    public func reopensInWebKit(engineIsChromium: Bool, enginePinned: Bool, alreadyReopened: Bool) -> Bool {
        _ = (engineIsChromium, enginePinned, alreadyReopened)
        return false
    }

    /// The binding the relay script calls in the media world (`BrowserMediaState.world`).
    static let channel = "cmuxProtectedMedia"
    /// The `<html>` attribute the page-world probe writes the refused key system to (DOM attributes
    /// cross worlds; a `CustomEvent`'s detail may not).
    static let attribute = "data-cmux-protected-media-refused"
    /// The event the probe sends after writing ``attribute``.
    static let event = "cmux-protected-media-refused"

    /// The page-world probe: wraps `Navigator.prototype.requestMediaKeySystemAccess`; when a
    /// protected key system is refused and no protected request of the document succeeded within
    /// 1.5 s (sites probe several configurations first), it reports the key system once per
    /// document. The page gets the original result either way.
    public static let probeScript = """
    (() => {
      const proto = globalThis.Navigator && Navigator.prototype;
      const original = proto && proto.requestMediaKeySystemAccess;
      if (typeof original !== "function" || original.__cmuxProbe) return;
      const isProtected = (name) => /^(com\\.widevine\\.alpha|com\\.microsoft\\.playready|com\\.apple\\.fps)(\\.|$)/i.test(name);
      let granted = false;
      let reported = false;
      const report = (name) => {
        if (granted || reported) return;
        reported = true;
        const root = document.documentElement;
        if (!root) return;
        root.setAttribute("\(attribute)", name);
        document.dispatchEvent(new Event("\(event)"));
      };
      const probe = function requestMediaKeySystemAccess(keySystem, configurations) {
        const result = original.call(this, keySystem, configurations);
        const name = String(keySystem);
        if (isProtected(name)) {
          result.then(() => { granted = true; }, () => { setTimeout(() => report(name), 1500); });
        }
        return result;
      };
      Object.defineProperty(probe, "__cmuxProbe", { value: true });
      Object.defineProperty(probe, "toString", { value: () => original.toString() });
      Object.defineProperty(proto, "requestMediaKeySystemAccess", { value: probe, writable: true, configurable: true });
    })();
    """

    /// The media-world relay: reads ``attribute`` when ``event`` comes and calls ``channel``.
    static let relayScript = """
    (() => {
      let tries = 0;
      const send = () => {
        const name = document.documentElement && document.documentElement.getAttribute("\(attribute)");
        if (!name) return;
        if (typeof \(channel) === "function") { \(channel)(name); return; }
        if (++tries < 40) setTimeout(send, 50);
      };
      document.addEventListener("\(event)", send, true);
    })();
    """

    /// The key system a raw DevTools `Runtime.bindingCalled` of ``channel`` reports, nil for any
    /// other message.
    ///
    /// - Parameter json: One raw DevTools message.
    /// - Returns: The refused media, or nil.
    public static func refused(bindingCall json: String) -> BrowserProtectedMedia? {
        guard json.contains("\"\(channel)\""), let data = json.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              message["method"] as? String == "Runtime.bindingCalled",
              let params = message["params"] as? [String: Any], params["name"] as? String == channel,
              let payload = params["payload"] as? String, !payload.isEmpty, payload.count <= 128 else { return nil }
        return BrowserProtectedMedia(keySystem: payload)
    }
}

extension BrowserProtectedMedia {
    /// The note the reopened WebKit tab shows.
    public static var reopenedNotice: String {
        String(localized: "browser.protectedMedia.reopenedInWebKit",
               defaultValue: "Opened in WebKit: this site’s protected media does not play in Chromium.", bundle: .module)
    }
}

/// Web notifications in a Chromium page answer "denied" at once, as in
/// WebKit tabs (``BrowserPagePermissionPolicy`` denies notifications).
///
/// Chromium runs with notifications switched off (`--disable-notifications`:
/// its Alerts helper must not ask macOS for notification permission), and
/// then `Notification.requestPermission()` never settles: no prompt reaches
/// cmux to deny. This document-start script, in every frame of the page's
/// world, reports `Notification.permission` as "denied" and settles
/// `requestPermission` (promise and legacy callback) with "denied".
public enum BrowserNotificationDenialScript {
    /// The script's source.
    public static let source = """
    (() => {
      const N = globalThis.Notification;
      if (typeof N !== "function") return;
      try {
        Object.defineProperty(N, "permission", { get: () => "denied", configurable: true });
        const requestPermission = function (callback) {
          if (typeof callback === "function") { try { callback("denied"); } catch (_) {} }
          return Promise.resolve("denied");
        };
        Object.defineProperty(N, "requestPermission", { value: requestPermission, configurable: true, writable: true });
      } catch (_) {}
    })();
    """

    /// The user script to add to a Chromium page.
    public static var userScript: BrowserPageUserScript {
        BrowserPageUserScript(source: source, injectionTime: .documentStart, isMainFrameOnly: false, world: .page)
    }
}

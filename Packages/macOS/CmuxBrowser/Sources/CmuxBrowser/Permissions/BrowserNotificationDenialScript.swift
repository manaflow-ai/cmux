/// Web notifications in a Chromium page answer "denied" at once, as in
/// WebKit tabs (``BrowserPagePermissionPolicy`` denies notifications).
///
/// Chromium runs with notifications switched off (`--disable-notifications`:
/// its Alerts helper must not ask macOS for notification permission), which
/// removes the `Notification` API: a page calling
/// `Notification.requestPermission()` throws and never learns the answer.
/// This document-start script, in every frame of the page's world, gives the
/// page WebKit's behavior: a `Notification` whose `permission` is "denied",
/// whose `requestPermission` settles (promise and legacy callback) with
/// "denied", and whose constructor throws as a denied one does.
public enum BrowserNotificationDenialScript {
    /// The script's source.
    public static let source = """
    (() => {
      try {
        const requestPermission = function (callback) {
          if (typeof callback === "function") { try { callback("denied"); } catch (_) {} }
          return Promise.resolve("denied");
        };
        let N = globalThis.Notification;
        if (typeof N !== "function") {
          N = function Notification() {
            throw new TypeError("Failed to construct 'Notification': permission has not been granted.");
          };
          Object.defineProperty(N, "maxActions", { value: 0, configurable: true });
          Object.defineProperty(globalThis, "Notification", { value: N, configurable: true, writable: true });
        }
        Object.defineProperty(N, "permission", { get: () => "denied", configurable: true });
        Object.defineProperty(N, "requestPermission", { value: requestPermission, configurable: true, writable: true });
      } catch (_) {}
    })();
    """

    /// The user script to add to a Chromium page.
    public static var userScript: BrowserPageUserScript {
        BrowserPageUserScript(source: source, injectionTime: .documentStart, isMainFrameOnly: false, world: .page)
    }
}

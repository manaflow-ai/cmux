/// A guarded fallback for a Chromium page where the Notification API is
/// unavailable. Chromium runs with notifications disabled so this fallback
/// supplies WebKit's deterministic denied behavior: permission reads report
/// `denied`, requests settle with `denied`, and constructing a notification
/// throws. The denied members are installed even if a future build keeps a
/// native API, so a Chromium change cannot reintroduce a pending request.
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

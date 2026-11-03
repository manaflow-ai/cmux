import Foundation

/// The main frame's first contentful paint (Paint Timing, `first-contentful-paint`), reported once
/// per document from a script in its own isolated world, buffered so a paint before the observer
/// starts still counts. Both engines run it: WebKit reports no first paint to the app, and its
/// `didFinish` comes at the end of the load, long after a heavy page is on screen; Chromium with
/// the renderer paths (fork API 29) gets it without a DevTools session (`CEFFirstPaintBridge`).
nonisolated struct BrowserFirstPaintScript {
    static let channel = "cmuxFirstPaint"
    static let world = "cmuxFirstPaint"

    /// The script, with `post` the statement that reports (it may use `report`, always `true`) and
    /// `ready` the expression that says the report channel exists.
    static func source(post: String, ready: String) -> String {
        """
        (() => {
          if (typeof PerformanceObserver !== 'function') return;
          try {
            const observer = new PerformanceObserver((list) => {
              if (!list.getEntriesByName('first-contentful-paint').length) return;
              observer.disconnect();
              let waited = 0;
              const send = () => {
                // PROBE (reopen-f4, rpk 1-in-31): the channel can be missing when the paint comes; say how long it waited.
                if (!(\(ready))) { if (waited++ < 200) setTimeout(send, 25); return; }
                const report = waited === 0 ? true : 'late' + waited;
                \(post);
              };
              send();
            });
            observer.observe({ type: 'paint', buffered: true });
          } catch (_) {}
        })();
        """
    }
}

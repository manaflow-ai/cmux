import AppKit
import Foundation

/// Docked DevTools. CEF cannot parent its native DevTools browser to an
/// NSView on macOS (DevTools must be Chrome style; Chrome style with a native
/// parent is unsupported there, CEF issue #3294), so docked DevTools uses the
/// standard embedder pattern instead: an ordinary embedded browser loading
/// the DevTools frontend for the inspected page from the Chrome DevTools
/// Protocol endpoint. Requires CEFConfiguration.remoteDebuggingPort != 0.
public enum CEFDevTools {
    public static var isDockingAvailable: Bool {
        CEFApp.shared.remoteDebuggingPort != 0
    }

    /// Opens the DevTools frontend for `browser` inside `containerView`
    /// (host it in a CEFBrowserContainerView, e.g. a split alongside the
    /// page). The returned browser is a normal CEFBrowser; close it with
    /// `close(force:)` to dismiss the dock. Completion runs on the main
    /// thread with nil if the CDP endpoint is disabled or the target can't
    /// be resolved.
    public static func openDocked(
        for browser: CEFBrowser,
        in containerView: NSView,
        delegate: CEFBrowserDelegate? = nil,
        completion: @escaping (CEFBrowser?) -> Void
    ) {
        let port = CEFApp.shared.remoteDebuggingPort
        guard port != 0, let inspectedURL = browser.url else {
            completion(nil)
            return
        }
        frontendURL(port: port, inspectedURL: inspectedURL) { frontend in
            guard let frontend else {
                completion(nil)
                return
            }
            CEFBrowser.create(
                in: containerView,
                frame: containerView.bounds,
                url: frontend,
                delegate: delegate
            ) { devToolsBrowser in
                if let devToolsBrowser {
                    applyEmbedderDefaults(to: devToolsBrowser)
                }
                completion(devToolsBrowser)
            }
        }
    }

    /// The standalone DevTools frontend assumes it inspects a page on
    /// another device and defaults to mirroring it in a screencast pane.
    /// Embedded right next to the live page that mirror is a confusing
    /// duplicate, so default it off — once per profile, so a user who
    /// deliberately re-enables the toggle keeps their choice. Runs on every
    /// main-frame load (idempotent via the marker key); the reload applies
    /// the setting when the frontend already started with screencast on.
    static func applyEmbedderDefaults(to devToolsBrowser: CEFBrowser) {
        let script = """
        (() => {
          try {
            if (localStorage.getItem('cefkit-screencast-defaulted')) { return; }
            localStorage.setItem('cefkit-screencast-defaulted', '1');
            if (localStorage.getItem('screencast-enabled') !== 'false' ||
                localStorage.getItem('screencastEnabled') !== 'false') {
              localStorage.setItem('screencast-enabled', 'false');
              localStorage.setItem('screencastEnabled', 'false');
              location.reload();
            }
          } catch (e) {}
        })();
        """
        devToolsBrowser.onLoadEnd = { browser in
            browser.executeJavaScript(script)
        }
        // The frontend may already have finished loading before onLoadEnd
        // was installed; run once directly too (no-ops pre-context).
        devToolsBrowser.executeJavaScript(script)
    }

    /// Resolves the CDP target whose URL matches the inspected page and
    /// builds the frontend URL from its devtoolsFrontendUrl.
    static func frontendURL(port: Int, inspectedURL: String, completion: @escaping (String?) -> Void) {
        guard let listURL = URL(string: "http://127.0.0.1:\(port)/json") else {
            completion(nil)
            return
        }
        let task = URLSession.shared.dataTask(with: listURL) { data, _, _ in
            var result: String?
            if let data,
               let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                let match = targets.first { target in
                    target["type"] as? String == "page" && target["url"] as? String == inspectedURL
                }
                if let frontendPath = match?["devtoolsFrontendUrl"] as? String {
                    result = frontendPath.hasPrefix("http")
                        ? frontendPath
                        : "http://127.0.0.1:\(port)\(frontendPath)"
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
        task.resume()
    }
}

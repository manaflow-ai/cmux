import AppKit
import Foundation

// Docked DevTools. CEF cannot parent its native DevTools browser to an
// NSView on macOS (DevTools must be Chrome style; Chrome style with a native
// parent is unsupported there, CEF issue #3294), so docked DevTools uses the
// standard embedder pattern instead: an ordinary embedded browser loading
// the DevTools frontend for the inspected page from the Chrome DevTools
// Protocol endpoint. Requires CEFConfiguration.remoteDebuggingPort != 0.

extension CEFApp {
    /// Whether embedded DevTools (docked pane or app-owned window) can be
    /// opened; requires CEFConfiguration.remoteDebuggingPort != 0.
    public var isDevToolsDockingAvailable: Bool {
        remoteDebuggingPort != 0
    }

    /// Resolves the CDP target whose URL matches the inspected page and
    /// builds the frontend URL from its devtoolsFrontendUrl. Completion runs
    /// on the main thread.
    func devToolsFrontendURL(inspectedURL: String, completion: @escaping (String?) -> Void) {
        let port = remoteDebuggingPort
        guard port != 0, let listURL = URL(string: "http://127.0.0.1:\(port)/json") else {
            completion(nil)
            return
        }
        let task = URLSession.shared.dataTask(with: listURL) { data, _, _ in
            var result: String?
            if let data,
               let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                // Known limitation: the CDP target list carries no browser
                // identity, so the inspected page is matched by exact URL.
                // When several browsers show the same URL this picks the
                // first, and a URL that drifted mid-navigation resolves nil
                // (the caller completes nil and the user retries).
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

extension CEFBrowser {
    /// Opens the DevTools frontend for this browser inside `containerView`
    /// (host it in a CEFBrowserContainerView, e.g. a split alongside the
    /// page). The returned browser is a normal CEFBrowser; close it with
    /// `close(force:)` to dismiss the dock. Completion runs on the main
    /// thread with nil if the CDP endpoint is disabled or the target can't
    /// be resolved.
    public func openDockedDevTools(
        in containerView: NSView,
        delegate: CEFBrowserDelegate? = nil,
        completion: @escaping (CEFBrowser?) -> Void
    ) {
        guard CEFApp.shared.isDevToolsDockingAvailable, let inspectedURL = url else {
            completion(nil)
            return
        }
        CEFApp.shared.devToolsFrontendURL(inspectedURL: inspectedURL) { frontend in
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
                devToolsBrowser?.applyDevToolsEmbedderDefaults()
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
    /// Call on the DevTools frontend browser itself.
    func applyDevToolsEmbedderDefaults() {
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
        onLoadEnd = { browser in
            browser.executeJavaScript(script)
        }
        // The frontend may already have finished loading before onLoadEnd
        // was installed; run once directly too (no-ops pre-context).
        executeJavaScript(script)
    }
}

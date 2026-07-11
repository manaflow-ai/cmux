import AppKit
import CCEF
import Foundation

// Docked DevTools. CEF cannot parent its native DevTools browser to an
// NSView on macOS (DevTools must be Chrome style; Chrome style with a native
// parent is unsupported there, CEF issue #3294), so docked DevTools uses the
// standard embedder pattern instead: an ordinary embedded browser loading
// the DevTools frontend for the inspected page from the Chrome DevTools
// Protocol endpoint. Requires CEFConfiguration.remoteDebuggingPort != 0.
//
// The inspected page is resolved by its CDP target id (fetched from the
// browser itself via Target.getTargetInfo), never by URL: several browsers
// commonly display the same URL, and a URL can drift mid-navigation, so URL
// matching could attach DevTools to the wrong browser.

extension CEFApp {
    /// Whether embedded DevTools (docked pane or app-owned window) can be
    /// opened; requires CEFConfiguration.remoteDebuggingPort != 0.
    public var isDevToolsDockingAvailable: Bool {
        remoteDebuggingPort != 0
    }

    /// Looks up the CDP target with the given id and builds the DevTools
    /// frontend URL from its devtoolsFrontendUrl. Completion runs on the
    /// main thread.
    func devToolsFrontendURL(targetId: String, completion: @escaping (String?) -> Void) {
        let port = remoteDebuggingPort
        guard port != 0, let listURL = URL(string: "http://127.0.0.1:\(port)/json") else {
            completion(nil)
            return
        }
        let task = URLSession.shared.dataTask(with: listURL) { data, _, _ in
            var result: String?
            if let data,
               let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                let match = targets.first { $0["id"] as? String == targetId }
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

/// One-shot CDP probe resolving a browser's DevTools target id via
/// Target.getTargetInfo. The observer struct allocation retains this object;
/// the registration returned by add_dev_tools_message_observer is released
/// when the probe finishes, which unregisters the observer and drops the
/// struct's references.
private final class CEFDevToolsTargetIdProbe {
    private var completion: ((String?) -> Void)?
    var registrationPtr: UnsafeMutablePointer<cef_registration_t>?
    var messageId: Int32 = 0

    init(completion: @escaping (String?) -> Void) {
        self.completion = completion
    }

    func finish(_ targetId: String?) {
        guard let completion else { return }
        self.completion = nil
        if let registrationPtr {
            self.registrationPtr = nil
            cefRelease(UnsafeMutableRawPointer(registrationPtr))
        }
        completion(targetId)
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
        guard CEFApp.shared.isDevToolsDockingAvailable else {
            completion(nil)
            return
        }
        devToolsFrontendURL { frontend in
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

    /// Resolves this browser's DevTools frontend URL: fetches the CDP target
    /// id from the browser itself, then matches it in the CDP endpoint's
    /// target list. Completion runs on the main thread.
    func devToolsFrontendURL(completion: @escaping (String?) -> Void) {
        fetchDevToolsTargetId { targetId in
            guard let targetId else {
                completion(nil)
                return
            }
            CEFApp.shared.devToolsFrontendURL(targetId: targetId, completion: completion)
        }
    }

    /// Asks the browser's own DevTools agent for its target id
    /// (Target.getTargetInfo), giving an exact identity mapping into the CDP
    /// /json target list regardless of the page URL. Must be called on the
    /// main thread; completion runs on the main thread.
    func fetchDevToolsTargetId(completion: @escaping (String?) -> Void) {
        let probe = CEFDevToolsTargetIdProbe(completion: completion)
        let observerPtr = CEFHandler.allocate(cef_dev_tools_message_observer_t.self, object: probe)
        observerPtr.pointee.on_dev_tools_method_result = { selfPtr, _, messageId, success, result, resultSize in
            guard let selfPtr else { return }
            let probe = CEFHandler.object(CEFDevToolsTargetIdProbe.self, from: selfPtr)
            guard messageId == probe.messageId else { return }
            var targetId: String?
            if success != 0, let result, resultSize > 0 {
                let data = Data(bytes: result, count: resultSize)
                if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let info = payload["targetInfo"] as? [String: Any] {
                    targetId = info["targetId"] as? String
                }
            }
            probe.finish(targetId)
        }
        // Pending results are dropped when the agent detaches; fail the probe
        // instead of leaving it (and its registration) pending forever.
        observerPtr.pointee.on_dev_tools_agent_detached = { selfPtr, _ in
            guard let selfPtr else { return }
            CEFHandler.object(CEFDevToolsTargetIdProbe.self, from: selfPtr).finish(nil)
        }
        var transferred = false
        var submitted = false
        withHost { host in
            guard let addObserver = host.pointee.add_dev_tools_message_observer else { return }
            // The observer struct's allocation reference transfers to CEF
            // here; the returned registration (owned +1) keeps it alive
            // until the probe finishes.
            probe.registrationPtr = addObserver(host, observerPtr)
            transferred = true
            let assigned = withCEFString("Target.getTargetInfo") { methodPtr in
                host.pointee.execute_dev_tools_method?(host, 0, methodPtr, nil) ?? 0
            }
            probe.messageId = assigned
            submitted = assigned != 0
        }
        if !transferred {
            // Closed browser: the allocation reference is still ours.
            cefRelease(UnsafeMutableRawPointer(observerPtr))
        }
        if !submitted {
            probe.finish(nil)
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

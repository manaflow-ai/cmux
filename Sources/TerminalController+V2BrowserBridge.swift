import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSocketControl
import CmuxSwiftRenderUI
import Carbon.HIToolbox
import CMUXMobileCore
import CMUXWorkstream
import Foundation
import Bonsplit
import WebKit


// MARK: - V2 browser panel resolution, JS bridge, and element refs
extension TerminalController {
    func v2BrowserWithPanel(
        params: [String: Any],
        _ body: (_ tabManager: TabManager, _ workspace: Workspace, _ surfaceId: UUID, _ browserPanel: BrowserPanel) -> V2CallResult
    ) -> V2CallResult {
        var result: V2CallResult = .err(code: "internal_error", message: "Browser operation failed", data: nil)
        v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                result = .err(code: "unavailable", message: "TabManager not available", data: nil)
                return
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let resolvedSurface = v2ResolveBrowserSurfaceId(params: params, workspace: ws)
            if let error = resolvedSurface.error {
                result = error
                return
            }
            let surfaceId = resolvedSurface.surfaceId
            guard let surfaceId else {
                result = .err(code: "not_found", message: "No focused browser surface", data: nil)
                return
            }
            guard let browserPanel = ws.browserPanel(for: surfaceId) else {
                result = .err(code: "invalid_params", message: "Surface is not a browser", data: ["surface_id": surfaceId.uuidString])
                return
            }
            result = body(tabManager, ws, surfaceId, browserPanel)
        }
        return result
    }

    func v2ResolveBrowserSurfaceId(
        params: [String: Any],
        workspace: Workspace
    ) -> (surfaceId: UUID?, error: V2CallResult?) {
        if let surfaceId = v2UUID(params, "surface_id") ?? v2UUID(params, "tab_id") {
            return (surfaceId, nil)
        }
        if let paneId = v2UUID(params, "pane_id") {
            guard let pane = workspace.bonsplitController.allPaneIds.first(where: { $0.id == paneId }) else {
                return (
                    nil,
                    .err(code: "not_found", message: "Pane not found", data: ["pane_id": paneId.uuidString])
                )
            }
            guard let selectedTab = workspace.bonsplitController.selectedTab(inPane: pane),
                  let selectedSurface = workspace.panelIdFromSurfaceId(selectedTab.id) else {
                return (
                    nil,
                    .err(code: "not_found", message: "Pane has no selected surface", data: ["pane_id": paneId.uuidString])
                )
            }
            return (selectedSurface, nil)
        }
        return (workspace.focusedPanelId, nil)
    }

    func v2JSONLiteral(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
           let text = String(data: data, encoding: .utf8),
           text.count >= 2 {
            return String(text.dropFirst().dropLast())
        }
        if let s = value as? String {
            return "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return "null"
    }

    func v2NormalizeJSValue(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        if value is V2BrowserUndefinedSentinel {
            return [
                Self.v2BrowserEvalEnvelopeTypeKey: Self.v2BrowserEvalEnvelopeTypeUndefined,
                Self.v2BrowserEvalEnvelopeValueKey: NSNull()
            ]
        }
        if value is NSNull { return NSNull() }
        if let v = value as? String { return v }
        if let v = value as? NSNumber { return v }
        if let v = value as? Bool { return v }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                out[k] = v2NormalizeJSValue(v)
            }
            return out
        }
        if let arr = value as? [Any] {
            return arr.map { v2NormalizeJSValue($0) }
        }
        return String(describing: value)
    }

    enum V2JavaScriptResult {
        case success(Any?)
        case failure(String)
    }

    func v2RunJavaScript(
        _ webView: WKWebView,
        script: String,
        timeout: TimeInterval = 5.0,
        preferAsync: Bool = false,
        contentWorld: WKContentWorld
    ) -> V2JavaScriptResult {
        let timeoutSeconds = max(0.01, timeout)
        let evaluator: (@escaping (Any?, String?) -> Void) -> Void = { finish in
            if preferAsync, #available(macOS 11.0, *) {
                webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: contentWorld) { result in
                    switch result {
                    case .success(let value):
                        finish(value, nil)
                    case .failure(let error):
                        finish(nil, error.localizedDescription)
                    }
                }
            } else {
                webView.evaluateJavaScript(script) { value, error in
                    if let error {
                        finish(nil, error.localizedDescription)
                    } else {
                        finish(value, nil)
                    }
                }
            }
        }

        let outcome: (Any?, String?)?
        if Thread.isMainThread {
            outcome = v2AwaitCallback(timeout: timeoutSeconds) { finish in
                evaluator { value, error in
                    finish((value, error))
                }
            }
        } else {
            outcome = v2AwaitCallback(timeout: timeoutSeconds) { finish in
                DispatchQueue.main.async {
                    evaluator { value, error in
                        finish((value, error))
                    }
                }
            }
        }

        guard let outcome else {
            return .failure("Timed out waiting for JavaScript result")
        }
        if let resultError = outcome.1 {
            return .failure(resultError)
        }
        return .success(outcome.0)
    }

    func v2AwaitCallback<T>(
        timeout: TimeInterval,
        start: (@escaping (T) -> Void) -> Void
    ) -> T? {
        if Thread.isMainThread {
            let runLoop = CFRunLoopGetCurrent()
            let lock = NSLock()
            var resolved = false
            var timedOut = false
            var result: T?

            let finish: (T) -> Void = { value in
                lock.lock()
                guard !resolved else {
                    lock.unlock()
                    return
                }
                resolved = true
                result = value
                lock.unlock()
                CFRunLoopStop(runLoop)
            }

            guard let timeoutTimer = CFRunLoopTimerCreateWithHandler(
                kCFAllocatorDefault,
                CFAbsoluteTimeGetCurrent() + timeout,
                0,
                0,
                0,
                { _ in
                    lock.lock()
                    if !resolved {
                        resolved = true
                        timedOut = true
                    }
                    lock.unlock()
                    CFRunLoopStop(runLoop)
                }
            ) else {
                return nil
            }
            CFRunLoopAddTimer(runLoop, timeoutTimer, .defaultMode)
            defer { CFRunLoopTimerInvalidate(timeoutTimer) }

            start(finish)
            while true {
                lock.lock()
                if resolved {
                    let value = result
                    let didTimeOut = timedOut
                    lock.unlock()
                    return didTimeOut ? nil : value
                }
                lock.unlock()

                CFRunLoopRun()
            }
        }

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: T?
        start { value in
            lock.lock()
            result = value
            lock.unlock()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    func v2WaitForBrowserCondition(
        _ webView: WKWebView,
        surfaceId: UUID,
        conditionScript: String,
        timeoutMs: Int
    ) -> Bool {
        let timeout = Double(timeoutMs) / 1000.0
        let waitScript = """
        (() => {
          const __cmuxEvaluate = () => {
            try {
              return !!(\(conditionScript));
            } catch (_) {
              return false;
            }
          };

          if (__cmuxEvaluate()) {
            return true;
          }

          return new Promise((resolve) => {
            let finished = false;
            let observer = null;
            const cleanups = [];
            const finish = (value) => {
              if (finished) return;
              finished = true;
              if (observer) observer.disconnect();
              for (const cleanup of cleanups) {
                try { cleanup(); } catch (_) {}
              }
              resolve(value);
            };
            const recheck = () => {
              if (__cmuxEvaluate()) {
                finish(true);
              }
            };
            const addListener = (target, eventName, options) => {
              if (!target || typeof target.addEventListener !== 'function') return;
              const handler = () => recheck();
              target.addEventListener(eventName, handler, options);
              cleanups.push(() => target.removeEventListener(eventName, handler, options));
            };

            try {
              observer = new MutationObserver(() => recheck());
              observer.observe(document.documentElement || document, {
                childList: true,
                subtree: true,
                attributes: true,
                characterData: true
              });
            } catch (_) {}

            addListener(document, 'readystatechange', true);
            addListener(window, 'load', true);
            addListener(window, 'pageshow', true);
            addListener(window, 'hashchange', true);
            addListener(window, 'popstate', true);

            const timeoutId = window.setTimeout(() => {
              finish(false);
            }, \(timeoutMs));
            cleanups.push(() => window.clearTimeout(timeoutId));
            recheck();
          });
        })()
        """

        switch v2RunBrowserJavaScript(
            webView,
            surfaceId: surfaceId,
            script: waitScript,
            timeout: timeout + 1.0,
            useEval: false
        ) {
        case .success(let value):
            return (value as? Bool) == true
        case .failure:
            return false
        }
    }

    func v2BrowserSelector(_ params: [String: Any]) -> String? {
        v2String(params, "selector")
            ?? v2String(params, "sel")
            ?? v2String(params, "element_ref")
            ?? v2String(params, "ref")
    }

    func v2BrowserNotSupported(_ method: String, details: String) -> V2CallResult {
        .err(code: "not_supported", message: "\(method) is not supported on WKWebView", data: ["details": details])
    }

    func v2BrowserAllocateElementRef(surfaceId: UUID, selector: String) -> String {
        let ref = "@e\(v2BrowserNextElementOrdinal)"
        v2BrowserNextElementOrdinal += 1
        v2BrowserElementRefs[ref] = V2BrowserElementRefEntry(surfaceId: surfaceId, selector: selector)
        return ref
    }

    func v2BrowserResolveSelector(_ rawSelector: String, surfaceId: UUID) -> String? {
        let trimmed = rawSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let refKey: String? = {
            if trimmed.hasPrefix("@e") { return trimmed }
            if trimmed.hasPrefix("e"), Int(trimmed.dropFirst()) != nil { return "@\(trimmed)" }
            return nil
        }()

        if let refKey {
            guard let entry = v2BrowserElementRefs[refKey], entry.surfaceId == surfaceId else { return nil }
            return entry.selector
        }
        return trimmed
    }

    private func v2BrowserCurrentFrameSelector(surfaceId: UUID) -> String? {
        v2BrowserFrameSelectorBySurface[surfaceId]
    }

    func v2RunBrowserJavaScript(
        _ webView: WKWebView,
        surfaceId: UUID,
        script: String,
        timeout: TimeInterval = 5.0,
        useEval: Bool = true
    ) -> V2JavaScriptResult {
        let scriptLiteral = v2JSONLiteral(script)
        let framePrelude: String
        if let frameSelector = v2BrowserCurrentFrameSelector(surfaceId: surfaceId) {
            let selectorLiteral = v2JSONLiteral(frameSelector)
            framePrelude = """
            let __cmuxDoc = document;
            try {
              const __cmuxFrame = document.querySelector(\(selectorLiteral));
              if (__cmuxFrame && __cmuxFrame.contentDocument) {
                __cmuxDoc = __cmuxFrame.contentDocument;
              }
            } catch (_) {}
            """
        } else {
            framePrelude = "const __cmuxDoc = document;"
        }

        let executionBlock: String
        if useEval {
            executionBlock = "const __r = eval(\(scriptLiteral));"
        } else {
            executionBlock = "const __r = \(script);"
        }

        let asyncFunctionBody = """
        \(framePrelude)

        const __cmuxMaybeAwait = async (__r) => {
          if (__r !== null && (typeof __r === 'object' || typeof __r === 'function') && typeof __r.then === 'function') {
            return await __r;
          }
          return __r;
        };

        const __cmuxEvalInFrame = async function() {
          const document = __cmuxDoc;
          \(executionBlock)
          const __value = await __cmuxMaybeAwait(__r);
          return {
            __cmux_t: (typeof __value === 'undefined') ? 'undefined' : 'value',
            __cmux_v: __value
          };
        };

        return await __cmuxEvalInFrame();
        """

        var rawResult: V2JavaScriptResult
        if #available(macOS 11.0, *) {
            rawResult = v2RunJavaScript(
                webView,
                script: asyncFunctionBody,
                timeout: timeout,
                preferAsync: true,
                contentWorld: .page
            )
        } else {
            let evaluateFallback = """
            (async () => {
              \(asyncFunctionBody)
            })()
            """
            rawResult = v2RunJavaScript(webView, script: evaluateFallback, timeout: timeout, contentWorld: .page)
        }

        if !useEval, case .failure(let pageMessage) = rawResult, #available(macOS 11.0, *) {
            let isolatedResult = v2RunJavaScript(
                webView,
                script: asyncFunctionBody,
                timeout: timeout,
                preferAsync: true,
                contentWorld: .defaultClient
            )
            switch isolatedResult {
            case .success:
                rawResult = isolatedResult
            case .failure(let isolatedMessage):
                if isolatedMessage != pageMessage {
                    rawResult = .failure("\(pageMessage) (isolated-world retry: \(isolatedMessage))")
                }
            }
        }

        switch rawResult {
        case .failure(let message):
            return .failure(message)
        case .success(let value):
            guard let dict = value as? [String: Any],
                  let type = dict[Self.v2BrowserEvalEnvelopeTypeKey] as? String else {
                return .success(value)
            }

            switch type {
            case Self.v2BrowserEvalEnvelopeTypeUndefined:
                return .success(v2BrowserUndefinedSentinel)
            case Self.v2BrowserEvalEnvelopeTypeValue:
                return .success(dict[Self.v2BrowserEvalEnvelopeValueKey])
            default:
                return .success(value)
            }
        }
    }

    func v2BrowserRecordUnsupportedRequest(surfaceId: UUID, request: [String: Any]) {
        var logs = v2BrowserUnsupportedNetworkRequestsBySurface[surfaceId] ?? []
        logs.append(request)
        if logs.count > 256 {
            logs.removeFirst(logs.count - 256)
        }
        v2BrowserUnsupportedNetworkRequestsBySurface[surfaceId] = logs
    }

    func v2BrowserPendingDialogs(surfaceId: UUID) -> [[String: Any]] {
        let queue = v2BrowserDialogQueueBySurface[surfaceId] ?? []
        return queue.enumerated().map { index, d in
            [
                "index": index,
                "type": d.type,
                "message": d.message,
                "default_text": v2OrNull(d.defaultText)
            ]
        }
    }

    func enqueueBrowserDialog(
        surfaceId: UUID,
        type: String,
        message: String,
        defaultText: String?,
        responder: @escaping (_ accept: Bool, _ text: String?) -> Void
    ) {
        var queue = v2BrowserDialogQueueBySurface[surfaceId] ?? []
        queue.append(V2BrowserPendingDialog(type: type, message: message, defaultText: defaultText, responder: responder))
        if queue.count > 16 {
            // Keep bounded memory while preserving FIFO semantics for newest entries.
            queue.removeFirst(queue.count - 16)
        }
        v2BrowserDialogQueueBySurface[surfaceId] = queue
    }

    private func v2BrowserPopDialog(surfaceId: UUID) -> V2BrowserPendingDialog? {
        var queue = v2BrowserDialogQueueBySurface[surfaceId] ?? []
        guard !queue.isEmpty else { return nil }
        let first = queue.removeFirst()
        v2BrowserDialogQueueBySurface[surfaceId] = queue
        return first
    }

    private func v2BrowserEnsureInitScriptsApplied(surfaceId: UUID, browserPanel: BrowserPanel) {
        let scripts = v2BrowserInitScriptsBySurface[surfaceId] ?? []
        let styles = v2BrowserInitStylesBySurface[surfaceId] ?? []
        guard !scripts.isEmpty || !styles.isEmpty else { return }

        let injector = """
        (() => {
          window.__cmuxInitScriptsApplied = window.__cmuxInitScriptsApplied || { scripts: [], styles: [] };
          return true;
        })()
        """
        _ = v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: injector)

        for script in scripts {
            _ = v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script)
        }
        for css in styles {
            let cssLiteral = v2JSONLiteral(css)
            let styleScript = """
            (() => {
              const id = 'cmux-init-style-' + btoa(unescape(encodeURIComponent(\(cssLiteral)))).replace(/=+$/g, '');
              if (document.getElementById(id)) return true;
              const el = document.createElement('style');
              el.id = id;
              el.textContent = String(\(cssLiteral));
              (document.head || document.documentElement || document.body).appendChild(el);
              return true;
            })()
            """
            _ = v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: styleScript)
        }
    }

    func v2PNGData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    func bestEffortPruneTemporaryFiles(
        in directoryURL: URL,
        keepingMostRecent maxCount: Int = 50,
        maxAge: TimeInterval = 24 * 60 * 60
    ) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let now = Date()
        let datedEntries = entries.compactMap { url -> (url: URL, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]),
                  values.isRegularFile == true else {
                return nil
            }
            return (url, values.contentModificationDate ?? values.creationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }

        for (index, entry) in datedEntries.enumerated() {
            if index >= maxCount || now.timeIntervalSince(entry.date) > maxAge {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }
    }

    // MARK: - Markdown

}

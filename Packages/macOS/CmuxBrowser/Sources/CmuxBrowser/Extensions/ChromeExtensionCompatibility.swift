// Approach adapted from Search (https://github.com/driceroland/Search,
// Sources/Search/ExtensionShims.swift at 491f3214063212fac176a7ad95467f0821040451),
// Copyright (c) 2026 Office Commun, MIT License. See THIRD_PARTY_LICENSES.md.

public import Foundation

/// Makes Chrome Web Store extensions take their Chrome code paths on WebKit.
///
/// Extensions pick a code path from `navigator.userAgent`. cmux tabs present
/// a Safari identity (sites need it), and WebKit gives extension pages and
/// workers that identity too, so an extension such as Bitwarden runs its
/// Safari path, which expects Safari's native companion app, and its popup
/// never finishes loading. This layer, installed into the extension's own
/// folder, changes only what the extension's pages and service worker see:
///
/// - `navigator.userAgent`, `appVersion`, and `vendor` report Chrome;
/// - Chrome enum constants WebKit leaves out (`chrome.scripting.ExecutionWorld`,
///   `chrome.runtime.ContextType`, ...) are defined;
/// - the patched namespace objects are kept alive, since WebKit may otherwise
///   collect a wrapper and hand out a fresh one without the constants;
/// - Chrome namespaces WebKit lacks (`notifications`, `downloads`, `idle`,
///   `management`, `privacy`, `storage.managed`, and missing `webRequest` and
///   `webNavigation` events) exist as inert stand-ins, so a worker that reads
///   them at startup keeps running.
///
/// It adds no capability: no native bridge, no new API, nothing visible to
/// websites, and the HTTP user agent is unchanged.
// lint:allow namespace-type: stateless Chrome-format rules (parsing, validation,
// generated source); callers pass their own FileManager/URLSession, so there is
// no dependency to inject into an instance.
public enum ChromeExtensionCompatibility {
    public static let preambleFile = "cmux-compat.js"
    public static let contentPreambleFile = "cmux-content-compat.js"
    public static let workerWrapperFile = "cmux-compat-worker.js"
    public static let moduleWorkerWrapperFile = "cmux-compat-worker.mjs"
    static let stateFile = ".cmux-compat.json"

    /// The Chrome identity extension contexts see.
    public static var chromeUserAgent: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
            + "Chrome/\(ChromeExtensionPackage.reportedChromeVersion) Safari/537.36"
    }

    public static var preambleSource: String {
        let userAgent = (try? JSONEncoder().encode(chromeUserAgent)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return """
        // Added by cmux: extension pages and workers see a Chrome identity and
        // the Chrome constants WebKit leaves out. Websites are unaffected.
        (function () {
          var ua = \(userAgent);
          var protos = [];
          if (typeof Navigator !== "undefined") protos.push(Navigator.prototype);
          if (typeof WorkerNavigator !== "undefined") protos.push(WorkerNavigator.prototype);
          protos.forEach(function (p) {
            try { Object.defineProperty(p, "userAgent", { get: function () { return ua; }, configurable: true }); } catch (e) {}
            try { Object.defineProperty(p, "appVersion", { get: function () { return ua.slice(8); }, configurable: true }); } catch (e) {}
            try { Object.defineProperty(p, "vendor", { get: function () { return "Google Inc."; }, configurable: true }); } catch (e) {}
          });
        })();
        (function () {
          var api = (typeof chrome !== "undefined" && chrome) || (typeof browser !== "undefined" && browser);
          if (!api) return;
          var keep = (globalThis.__cmuxCompatNamespaces = globalThis.__cmuxCompatNamespaces || []);
          function define(ns, name, value) {
            try {
              var o = api[ns];
              if (!o) return;
              if (keep.indexOf(o) < 0) keep.push(o);
              if (o[name] !== undefined) return;
              var frozen = Object.freeze(value);
              var proto = Object.getPrototypeOf(o);
              if (proto && proto !== Object.prototype) {
                Object.defineProperty(proto, name, { value: frozen, configurable: true });
              }
              if (o[name] === undefined) Object.defineProperty(o, name, { value: frozen, configurable: true });
            } catch (e) {}
          }
          define("scripting", "ExecutionWorld", { ISOLATED: "ISOLATED", MAIN: "MAIN" });
          define("runtime", "ContextType", { TAB: "TAB", POPUP: "POPUP", BACKGROUND: "BACKGROUND", OFFSCREEN_DOCUMENT: "OFFSCREEN_DOCUMENT", SIDE_PANEL: "SIDE_PANEL", DEVELOPER_TOOLS: "DEVELOPER_TOOLS" });
          define("runtime", "OnInstalledReason", { INSTALL: "install", UPDATE: "update", CHROME_UPDATE: "chrome_update", SHARED_MODULE_UPDATE: "shared_module_update" });
          define("tabs", "TabStatus", { UNLOADED: "unloaded", LOADING: "loading", COMPLETE: "complete" });
          define("windows", "WindowType", { NORMAL: "normal", POPUP: "popup", PANEL: "panel", APP: "app", DEVTOOLS: "devtools" });
          define("contextMenus", "ContextType", { ALL: "all", PAGE: "page", FRAME: "frame", SELECTION: "selection", LINK: "link", EDITABLE: "editable", IMAGE: "image", VIDEO: "video", AUDIO: "audio", LAUNCHER: "launcher", BROWSER_ACTION: "browser_action", PAGE_ACTION: "page_action", ACTION: "action" });
          define("offscreen", "Reason", { CLIPBOARD: "CLIPBOARD", DOM_PARSER: "DOM_PARSER", LOCAL_STORAGE: "LOCAL_STORAGE", WORKERS: "WORKERS", BLOBS: "BLOBS" });
        })();
        // Chrome namespaces and events WebKit leaves out. Extensions read
        // them at startup (1Password's worker stops on
        // chrome.notifications.onClicked), so they exist here: events accept
        // listeners and never fire, queries answer empty, and actions fail
        // with "not available in cmux". Nothing here reaches native code.
        (function () {
          var api = (typeof chrome !== "undefined" && chrome) || (typeof browser !== "undefined" && browser);
          if (!api) return;
          var keep = (globalThis.__cmuxCompatNamespaces = globalThis.__cmuxCompatNamespaces || []);
          function event() {
            var listeners = [];
            return {
              addListener: function (f) { if (typeof f === "function" && listeners.indexOf(f) < 0) listeners.push(f); },
              removeListener: function (f) { var i = listeners.indexOf(f); if (i >= 0) listeners.splice(i, 1); },
              hasListener: function (f) { return listeners.indexOf(f) >= 0; },
              hasListeners: function () { return listeners.length > 0; }
            };
          }
          function unavailable(what) {
            return function () {
              var args = Array.prototype.slice.call(arguments);
              var callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
              var error = new Error(what + " is not available in cmux");
              if (!callback) return Promise.reject(error);
              try { Object.defineProperty(api.runtime, "lastError", { value: { message: error.message }, configurable: true }); } catch (e) {}
              try { callback(); } finally { try { delete api.runtime.lastError; } catch (e) {} }
            };
          }
          function answer(value) {
            return function () {
              var args = Array.prototype.slice.call(arguments);
              var callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
              if (callback) { callback(value); return; }
              return Promise.resolve(value);
            };
          }
          function put(target, name, value) {
            try { Object.defineProperty(target, name, { value: value, configurable: true, writable: true, enumerable: true }); } catch (e) {}
          }
          function define(name, build) {
            var ns = api[name];
            if (!ns) { ns = {}; put(api, name, ns); }
            if (typeof browser !== "undefined" && browser && browser !== api && !browser[name]) put(browser, name, ns);
            if (keep.indexOf(ns) < 0) keep.push(ns);
            var parts = build();
            var proto = Object.getPrototypeOf(ns);
            Object.keys(parts).forEach(function (key) {
              if (ns[key] !== undefined) return;
              if (proto && proto !== Object.prototype) put(proto, key, parts[key]);
              if (ns[key] === undefined) put(ns, key, parts[key]);
            });
          }
          function events(names) { var o = {}; names.forEach(function (n) { o[n] = event(); }); return o; }
          function methods(space, names) { var o = {}; names.forEach(function (n) { o[n] = unavailable("chrome." + space + "." + n); }); return o; }
          function merge() { var o = {}; Array.prototype.forEach.call(arguments, function (p) { Object.keys(p).forEach(function (k) { o[k] = p[k]; }); }); return o; }
          function setting() {
            return { get: answer({ value: false, levelOfControl: "not_controllable" }), set: unavailable("Changing this setting"), clear: unavailable("Changing this setting"), onChange: event() };
          }

          define("notifications", function () { return merge(
            methods("notifications", ["create", "update"]),
            { clear: answer(false), getAll: answer({}), getPermissionLevel: answer("denied"),
              TemplateType: { BASIC: "basic", IMAGE: "image", LIST: "list", PROGRESS: "progress" },
              PermissionLevel: { GRANTED: "granted", DENIED: "denied" } },
            events(["onClicked", "onClosed", "onButtonClicked", "onPermissionLevelChanged", "onShowSettings"])); });
          define("downloads", function () { return merge(
            methods("downloads", ["download", "pause", "resume", "cancel", "open", "show", "showDefaultFolder", "erase", "removeFile", "getFileIcon", "acceptDanger", "setUiOptions"]),
            { search: answer([]) },
            events(["onCreated", "onChanged", "onErased", "onDeterminingFilename"])); });
          define("idle", function () { return merge(
            { queryState: answer("active"), setDetectionInterval: function () {}, getAutoLockDelay: answer(0),
              IdleState: { ACTIVE: "active", IDLE: "idle", LOCKED: "locked" } },
            events(["onStateChanged"])); });
          define("management", function () { return merge(
            methods("management", ["get", "setEnabled", "uninstall", "uninstallSelf", "launchApp", "createAppShortcut", "setLaunchType", "generateAppForLink", "getPermissionWarningsById", "getPermissionWarningsByManifest"]),
            { getAll: answer([]) },
            events(["onInstalled", "onUninstalled", "onEnabled", "onDisabled"])); });
          define("privacy", function () {
            var group = function (names) { var o = {}; names.forEach(function (n) { o[n] = setting(); }); return o; };
            return {
              services: group(["alternateErrorPagesEnabled", "autofillAddressEnabled", "autofillCreditCardEnabled", "autofillEnabled", "passwordSavingEnabled", "safeBrowsingEnabled", "safeBrowsingExtendedReportingEnabled", "searchSuggestEnabled", "spellingServiceEnabled", "translationServiceEnabled"]),
              network: group(["networkPredictionEnabled", "webRTCIPHandlingPolicy"]),
              websites: group(["adMeasurementEnabled", "doNotTrackEnabled", "fledgeEnabled", "hyperlinkAuditingEnabled", "protectedContentEnabled", "referrersEnabled", "relatedWebsiteSetsEnabled", "thirdPartyCookiesAllowed", "topicsEnabled"])
            };
          });
          define("webRequest", function () { return merge(
            { handlerBehaviorChanged: answer(undefined), MAX_HANDLER_BEHAVIOR_CHANGED_CALLS_PER_10_MINUTES: 20 },
            events(["onBeforeRequest", "onBeforeSendHeaders", "onSendHeaders", "onHeadersReceived", "onAuthRequired", "onResponseStarted", "onBeforeRedirect", "onCompleted", "onErrorOccurred", "onActionIgnored"])); });
          define("contextMenus", function () {
            var menus = api.menus;
            if (menus) return { create: menus.create && menus.create.bind(menus), update: menus.update && menus.update.bind(menus), remove: menus.remove && menus.remove.bind(menus), removeAll: menus.removeAll && menus.removeAll.bind(menus), onClicked: menus.onClicked, ACTION_MENU_TOP_LEVEL_LIMIT: 6 };
            return merge(methods("contextMenus", ["create", "update", "remove", "removeAll"]), events(["onClicked"]));
          });
          define("webNavigation", function () { return merge(
            { getFrame: answer(null), getAllFrames: answer([]) },
            events(["onBeforeNavigate", "onCommitted", "onDOMContentLoaded", "onCompleted", "onErrorOccurred", "onCreatedNavigationTarget", "onReferenceFragmentUpdated", "onTabReplaced", "onHistoryStateUpdated"])); });
          // Enterprise policy storage: cmux sets no policies, so it is empty.
          var managed = merge(
            { get: answer({}), getBytesInUse: answer(0), set: unavailable("chrome.storage.managed.set"), remove: unavailable("chrome.storage.managed.remove"), clear: unavailable("chrome.storage.managed.clear") },
            events(["onChanged"]));
          [typeof chrome !== "undefined" && chrome, typeof browser !== "undefined" && browser].forEach(function (root) {
            var storage = root && root.storage;
            if (!storage || storage.managed) return;
            if (keep.indexOf(storage) < 0) keep.push(storage);
            var proto = Object.getPrototypeOf(storage);
            if (proto && proto !== Object.prototype) put(proto, "managed", managed);
            if (!storage.managed) put(storage, "managed", managed);
          });
          define("offscreen", function () { return merge(
            methods("offscreen", ["createDocument", "closeDocument"]), { hasDocument: answer(false) }); });
        })();
        """
    }

    /// Loaded before an extension's isolated-world content scripts.
    public static var contentPreambleSource: String {
        """
        // Added by cmux: content scripts run in the extension's isolated world, where
        // Chrome lets the <style> elements they add ignore the page's style-src
        // policy. WebKit applies the page policy, so a page with a strict policy
        // (api.github.com: default-src 'none') leaves them unstyled. A style element
        // this world creates is copied into a constructed style sheet, which the page
        // policy does not govern, when this world inserts or edits it. Page script
        // edits never reach the copy; removing the element drops it.
        (function () {
          if (typeof document === "undefined" || typeof CSSStyleSheet !== "function" || !("adoptedStyleSheets" in Document.prototype)) return;
          // Only in an extension's isolated world: page-world code has no runtime id.
          var api = typeof chrome === "object" && chrome;
          if (!api || !api.runtime || !api.runtime.id) return;
          if (globalThis.__cmuxContentCompat) return;
          globalThis.__cmuxContentCompat = true;
          var ours = new WeakSet();
          var mirrors = new Map();
          function sync(style) {
            var mirror = mirrors.get(style);
            if (!style.isConnected || style.ownerDocument !== document || style.sheet) {
              if (mirror) {
                document.adoptedStyleSheets = document.adoptedStyleSheets.filter(function (s) { return s !== mirror; });
                mirrors.delete(style);
              }
              return;
            }
            if (!mirror) {
              mirror = new CSSStyleSheet();
              mirrors.set(style, mirror);
              document.adoptedStyleSheets = document.adoptedStyleSheets.concat([mirror]);
            }
            try { mirror.replaceSync(style.textContent || ""); } catch (e) {}
          }
          function touch(node) {
            if (!node) return;
            if (node instanceof HTMLStyleElement) { if (ours.has(node)) sync(node); return; }
            if (node.querySelectorAll) node.querySelectorAll("style").forEach(function (s) { if (ours.has(s)) sync(s); });
          }
          function wrap(proto, name, after) {
            var original = proto[name];
            if (typeof original !== "function") return;
            proto[name] = function () {
              var result = original.apply(this, arguments);
              try { after(this, arguments, result); } catch (e) {}
              return result;
            };
          }
          var create = Document.prototype.createElement;
          Document.prototype.createElement = function () {
            var element = create.apply(this, arguments);
            if (element instanceof HTMLStyleElement) ours.add(element);
            return element;
          };
          // Inserting: the moved nodes, and the target when it is one of our styles.
          function inserted(target, args) {
            Array.prototype.forEach.call(args, function (a) { if (a && typeof a === "object") touch(a); });
            touch(target);
          }
          ["appendChild", "insertBefore", "replaceChild"].forEach(function (n) { wrap(Node.prototype, n, inserted); });
          ["append", "prepend", "before", "after", "replaceWith", "insertAdjacentElement", "insertAdjacentHTML", "insertAdjacentText", "replaceChildren"].forEach(function (n) {
            wrap(Element.prototype, n, function (target, args) {
              inserted(target, args);
              if (target.parentNode) touch(target.parentNode);
            });
          });
          var text = Object.getOwnPropertyDescriptor(Node.prototype, "textContent");
          if (text && text.set) {
            Object.defineProperty(Node.prototype, "textContent", {
              configurable: true, enumerable: text.enumerable, get: text.get,
              set: function (value) { text.set.call(this, value); touch(this); }
            });
          }
          // Removal by anyone drops the copy; nothing the page does adds to it.
          new MutationObserver(function (records) {
            records.forEach(function (record) {
              record.removedNodes.forEach(function (node) {
                mirrors.forEach(function (_, style) { if (style === node || (node.contains && node.contains(style))) sync(style); });
              });
            });
          }).observe(document, { childList: true, subtree: true });
        })();
        """
    }

    /// Where the original background worker is, so re-applying is idempotent.
    struct State: Codable, Equatable {
        var serviceWorker: String?
        var isModule: Bool
    }

    static let beginMarker = "// cmux-compat begin"
    static let endMarker = "// cmux-compat end"

    /// Installs the compatibility layer into an unpacked extension folder.
    /// Safe to run on every load: it rewrites only what it owns.
    ///
    /// The background worker keeps its own file and manifest entry: a module
    /// worker gets `import "/cmux-compat.js";` as its first line (imports run
    /// in order, before its own body), and a classic worker gets the preamble
    /// written at the top of the file between markers.
    public static func install(into folder: URL, fileManager: FileManager = .default) throws {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any] else { return }
        try Data(preambleSource.utf8).write(to: folder.appendingPathComponent(preambleFile), options: .atomic)

        var background = manifest["background"] as? [String: Any] ?? [:]
        var changedManifest = false

        // Undo the wrapper layout earlier builds wrote.
        let stateURL = folder.appendingPathComponent(stateFile)
        if let worker = background["service_worker"] as? String,
           worker == workerWrapperFile || worker == moduleWorkerWrapperFile,
           let data = try? Data(contentsOf: stateURL),
           let state = try? JSONDecoder().decode(State.self, from: data),
           let original = state.serviceWorker,
           // The state file sits in the extension folder; trust only a path
           // that is still a regular file inside it.
           containedFile(original, in: folder) != nil {
            background["service_worker"] = original
            changedManifest = true
            try? fileManager.removeItem(at: folder.appendingPathComponent(worker))
            try? fileManager.removeItem(at: stateURL)
        }

        if let worker = background["service_worker"] as? String,
           let workerURL = containedFile(worker, in: folder),
           var source = try? String(contentsOf: workerURL, encoding: .utf8) {
            let isModule = (background["type"] as? String) == "module"
            source = strippingPreamble(from: source)
            let prefixed = isModule
                ? "import \"/\(preambleFile)\";\n" + source
                : beginMarker + "\n" + preambleSource + "\n" + endMarker + "\n" + source
            try Data(prefixed.utf8).write(to: workerURL, options: .atomic)
        } else if var scripts = background["scripts"] as? [String], scripts.first != preambleFile {
            scripts.insert(preambleFile, at: 0)
            background["scripts"] = scripts
            changedManifest = true
        }
        try Data(contentPreambleSource.utf8).write(to: folder.appendingPathComponent(contentPreambleFile), options: .atomic)
        if let scripts = manifest["content_scripts"] as? [[String: Any]] {
            let prefixed = prefixingContentScripts(scripts)
            if !NSArray(array: prefixed).isEqual(to: scripts) {
                manifest["content_scripts"] = prefixed
                changedManifest = true
            }
        }
        if changedManifest {
            if !background.isEmpty { manifest["background"] = background }
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: manifestURL, options: .atomic)
        }
        try injectIntoPages(in: folder, fileManager: fileManager)
    }

    /// Puts the content preamble first in every isolated-world content script
    /// entry. Main-world entries run as page code and are left alone.
    static func prefixingContentScripts(_ scripts: [[String: Any]]) -> [[String: Any]] {
        let generated: Set<String> = [preambleFile, contentPreambleFile]
        return scripts.compactMap { entry in
            guard var js = entry["js"] as? [String], !js.isEmpty else { return entry }
            var entry = entry
            if (entry["world"] as? String)?.uppercased() == "MAIN" {
                // cmux's files never run as page code, even if a manifest names them.
                js.removeAll { generated.contains(Self.normalizedScriptPath($0)) }
                if js.isEmpty && ((entry["css"] as? [String]) ?? []).isEmpty { return nil }
            } else if js.first != contentPreambleFile {
                js = [contentPreambleFile] + js.filter { Self.normalizedScriptPath($0) != contentPreambleFile }
            }
            entry["js"] = js
            return entry
        }
    }

    private static func normalizedScriptPath(_ path: String) -> String {
        var path = path
        while path.hasPrefix("/") || path.hasPrefix("./") { path.removeFirst(path.hasPrefix("/") ? 1 : 2) }
        return path
    }

    /// Removes a preamble an earlier load added, so re-applying replaces it.
    static func strippingPreamble(from source: String) -> String {
        var source = source
        let moduleLine = "import \"/\(preambleFile)\";\n"
        while source.hasPrefix(moduleLine) { source.removeFirst(moduleLine.count) }
        if source.hasPrefix(beginMarker), let end = source.range(of: endMarker + "\n") {
            source = String(source[end.upperBound...])
        }
        return source
    }

    /// A worker path inside `folder` that is a regular file, not a link.
    private static func containedFile(_ path: String, in folder: URL) -> URL? {
        guard isSafeRelativePath(path) else { return nil }
        let url = folder.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path
        guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root + "/") else { return nil }
        return url
    }

    /// Adds the preamble as the first script of every HTML page the extension
    /// ships (popup, options, side panel, offscreen documents).
    static func injectIntoPages(in folder: URL, fileManager: FileManager) throws {
        let tag = "<script src=\"/\(preambleFile)\"></script>"
        guard let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return }
        for case let url as URL in enumerator where ["html", "htm"].contains(url.pathExtension.lowercased()) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let html = try? String(contentsOf: url, encoding: .utf8),
                  !html.contains(tag) else { continue }
            try Data(injectingPreamble(into: html, tag: tag).utf8).write(to: url, options: .atomic)
        }
    }

    static func injectingPreamble(into html: String, tag: String) -> String {
        if let head = html.range(of: #"<head\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            return html.replacingCharacters(in: head.upperBound..<head.upperBound, with: tag)
        }
        if let htmlTag = html.range(of: #"<html\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            return html.replacingCharacters(in: htmlTag.upperBound..<htmlTag.upperBound, with: "<head>\(tag)</head>")
        }
        return tag + html
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.contains("..") && !path.contains(":")
            && !path.contains { "\\\"'`\n\r".contains($0) }
    }
}

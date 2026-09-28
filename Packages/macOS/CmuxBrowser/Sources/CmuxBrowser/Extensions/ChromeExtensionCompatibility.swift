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
///   collect a wrapper and hand out a fresh one without the constants.
///
/// It adds no capability: no native bridge, no new API, nothing visible to
/// websites, and the HTTP user agent is unchanged.
public enum ChromeExtensionCompatibility {
    public static let preambleFile = "cmux-compat.js"
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
           let original = state.serviceWorker {
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
        if changedManifest {
            manifest["background"] = background
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: manifestURL, options: .atomic)
        }
        try injectIntoPages(in: folder, fileManager: fileManager)
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

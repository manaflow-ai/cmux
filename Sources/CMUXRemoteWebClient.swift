import Foundation

enum CMUXRemoteWebClient {
    struct Asset {
        let body: String
        let contentType: String
    }

    static func asset(path: String) -> Asset? {
        switch path {
        case "/", "/remote":
            return bundledAsset(relativePath: "index.html", contentType: "text/html; charset=utf-8")
        case "/remote/strings.json":
            return Asset(body: stringsJSON, contentType: "application/json; charset=utf-8")
        case "/remote/manifest.webmanifest":
            return Asset(body: manifest, contentType: "application/manifest+json; charset=utf-8")
        case "/remote/icon.svg", "/remote/maskable-icon.svg", "/remote/icon-maskable.svg":
            return Asset(body: iconSVG, contentType: "image/svg+xml; charset=utf-8")
        default:
            guard path.hasPrefix("/remote/") else { return nil }
            let relativePath = String(path.dropFirst("/remote/".count))
            guard relativePath.hasPrefix("assets/") else { return nil }
            return bundledAsset(relativePath: relativePath, contentType: contentType(for: relativePath))
        }
    }

    private struct LocalizedEntry {
        let id: String
        let key: StaticString
        let defaultValue: String.LocalizationValue

        init(_ id: String, key: StaticString, defaultValue: String.LocalizationValue) {
            self.id = id
            self.key = key
            self.defaultValue = defaultValue
        }
    }

    private static let localizedEntries: [LocalizedEntry] = [
        LocalizedEntry("appTitle", key: "remoteAccess.web.title", defaultValue: "cmux remote"),
        LocalizedEntry("productName", key: "remoteAccess.web.appName", defaultValue: "cmux"),
        LocalizedEntry("connectSubtitle", key: "remoteAccess.web.subtitle", defaultValue: "Connect to the running cmux app on this Mac."),
        LocalizedEntry("tokenLabel", key: "remoteAccess.web.token.label", defaultValue: "Remote access token"),
        LocalizedEntry("tokenPlaceholder", key: "remoteAccess.web.token.placeholder", defaultValue: "Paste token"),
        LocalizedEntry("connectButton", key: "remoteAccess.web.token.connect", defaultValue: "Connect"),
        LocalizedEntry("tokenHint", key: "remoteAccess.web.token.hint", defaultValue: "The token stays in this browser. Use Forget to remove it."),
        LocalizedEntry("status.disconnected", key: "remoteAccess.web.status.disconnected", defaultValue: "Disconnected"),
        LocalizedEntry("status.refreshing", key: "remoteAccess.web.status.refreshing", defaultValue: "Refreshing..."),
        LocalizedEntry("status.connected", key: "remoteAccess.web.status.connected", defaultValue: "Connected"),
        LocalizedEntry("status.live", key: "remoteAccess.web.status.live", defaultValue: "Live"),
        LocalizedEntry("status.reconnecting", key: "remoteAccess.web.status.reconnecting", defaultValue: "Reconnecting..."),
        LocalizedEntry("status.offline", key: "remoteAccess.web.status.offline", defaultValue: "Offline"),
        LocalizedEntry("status.creatingSession", key: "remoteAccess.web.status.creatingSession", defaultValue: "Creating session..."),
        LocalizedEntry("status.sessionCreated", key: "remoteAccess.web.status.sessionCreated", defaultValue: "Session created"),
        LocalizedEntry("status.creatingTab", key: "remoteAccess.web.status.creatingTab", defaultValue: "Creating tab..."),
        LocalizedEntry("status.tabCreated", key: "remoteAccess.web.status.tabCreated", defaultValue: "Tab created"),
        LocalizedEntry("refreshButton", key: "remoteAccess.web.action.refresh", defaultValue: "Refresh"),
        LocalizedEntry("forgetButton", key: "remoteAccess.web.action.forget", defaultValue: "Forget"),
        LocalizedEntry("newSessionButton", key: "remoteAccess.web.action.newSession", defaultValue: "New Session"),
        LocalizedEntry("creatingSessionButton", key: "remoteAccess.web.action.creatingSession", defaultValue: "Creating..."),
        LocalizedEntry("newTabButton", key: "remoteAccess.web.action.newTab", defaultValue: "New Tab"),
        LocalizedEntry("creatingTabButton", key: "remoteAccess.web.action.creatingTab", defaultValue: "Creating..."),
        LocalizedEntry("sessionsTitle", key: "remoteAccess.web.sessions.title", defaultValue: "Sessions"),
        LocalizedEntry("noTerminalSelected", key: "remoteAccess.web.terminal.noSelectionTitle", defaultValue: "No terminal selected"),
        LocalizedEntry("selectTerminal", key: "remoteAccess.web.terminal.noSelectionMeta", defaultValue: "Select a terminal surface."),
        LocalizedEntry("readButton", key: "remoteAccess.web.action.read", defaultValue: "Read"),
        LocalizedEntry("inputPlaceholder", key: "remoteAccess.web.terminal.inputPlaceholder", defaultValue: "Type input"),
        LocalizedEntry("sendButton", key: "remoteAccess.web.action.send", defaultValue: "Send"),
        LocalizedEntry("keyboardButton", key: "remoteAccess.web.action.keyboard", defaultValue: "Keyboard"),
        LocalizedEntry("terminalOutputLabel", key: "remoteAccess.web.terminal.outputLabel", defaultValue: "Terminal output"),
        LocalizedEntry("terminalKeysLabel", key: "remoteAccess.web.terminal.keysLabel", defaultValue: "Terminal keys"),
        LocalizedEntry("quickKeysLabel", key: "remoteAccess.web.terminal.quickKeysLabel", defaultValue: "Quick keys"),
        LocalizedEntry("terminalEmptyOutput", key: "remoteAccess.web.terminal.emptyOutput", defaultValue: "No output yet. Press Read to fetch the terminal."),
        LocalizedEntry("key.enter", key: "remoteAccess.web.key.enter", defaultValue: "Enter"),
        LocalizedEntry("key.escape", key: "remoteAccess.web.key.escape", defaultValue: "Esc"),
        LocalizedEntry("key.ctrlC", key: "remoteAccess.web.key.ctrlC", defaultValue: "Ctrl-C"),
        LocalizedEntry("key.tab", key: "remoteAccess.web.key.tab", defaultValue: "Tab"),
        LocalizedEntry("key.up", key: "remoteAccess.web.key.up", defaultValue: "Up"),
        LocalizedEntry("key.down", key: "remoteAccess.web.key.down", defaultValue: "Down"),
        LocalizedEntry("key.left", key: "remoteAccess.web.key.left", defaultValue: "Left"),
        LocalizedEntry("key.right", key: "remoteAccess.web.key.right", defaultValue: "Right"),
        LocalizedEntry("key.backspace", key: "remoteAccess.web.key.backspace", defaultValue: "Backspace"),
        LocalizedEntry("error.requestFailed", key: "remoteAccess.web.error.requestFailed", defaultValue: "Request failed ({status})"),
        LocalizedEntry("error.tokenRejected", key: "remoteAccess.web.error.tokenRejected", defaultValue: "Token was rejected."),
        LocalizedEntry("error.snapshotFailed", key: "remoteAccess.web.error.snapshotFailed", defaultValue: "Snapshot failed ({status})"),
        LocalizedEntry("error.createdTerminalNotFound", key: "remoteAccess.web.error.createdTerminalNotFound", defaultValue: "Created terminal was not found."),
        LocalizedEntry("error.createdTerminalNotReady", key: "remoteAccess.web.error.createdTerminalNotReady", defaultValue: "Created terminal did not start in time."),
        LocalizedEntry("tree.noWindows", key: "remoteAccess.web.sessions.noWindows", defaultValue: "No windows found."),
        LocalizedEntry("tree.workspaceFallback", key: "remoteAccess.web.workspace.fallback", defaultValue: "Workspace"),
        LocalizedEntry("tree.selected", key: "remoteAccess.web.workspace.selected", defaultValue: "selected"),
        LocalizedEntry("tree.windowPanes", key: "remoteAccess.web.workspace.meta", defaultValue: "window {window} - {panes} panes"),
        LocalizedEntry("tree.surfaceFallback", key: "remoteAccess.web.surface.fallback", defaultValue: "Surface"),
        LocalizedEntry("tree.surfaceTypeFallback", key: "remoteAccess.web.surface.typeFallback", defaultValue: "surface"),
        LocalizedEntry("tree.focusedSurface", key: "remoteAccess.web.surface.focused", defaultValue: "focused"),
        LocalizedEntry("terminalFallback", key: "remoteAccess.web.terminal.fallback", defaultValue: "Terminal"),
    ]

    private static var localizedStrings: [String: String] {
        Dictionary(uniqueKeysWithValues: localizedEntries.map { entry in
            (entry.id, String(localized: entry.key, defaultValue: entry.defaultValue))
        })
    }

    private static var stringsJSON: String {
        jsonString(localizedStrings)
    }

    private static func bundledAsset(relativePath: String, contentType: String) -> Asset? {
        guard !relativePath.isEmpty,
              !relativePath.split(separator: "/").contains("..") else {
            return nil
        }

        for baseURL in remoteWebBaseURLs() {
            let assetURL = baseURL.appendingPathComponent(relativePath, isDirectory: false).standardizedFileURL
            guard assetURL.path.hasPrefix(baseURL.standardizedFileURL.path + "/") else { continue }
            if let body = try? String(contentsOf: assetURL, encoding: .utf8) {
                return Asset(body: body, contentType: contentType)
            }
        }
        return nil
    }

    private static func remoteWebBaseURLs() -> [URL] {
        var urls: [URL] = []
        if let bundleURL = Bundle.main.resourceURL?.appendingPathComponent("RemoteWeb", isDirectory: true) {
            urls.append(bundleURL)
        }

        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        urls.append(currentDirectory.appendingPathComponent("Resources/RemoteWeb", isDirectory: true))
        urls.append(currentDirectory.deletingLastPathComponent().appendingPathComponent("Resources/RemoteWeb", isDirectory: true))
        return urls
    }

    private static func contentType(for relativePath: String) -> String {
        switch URL(fileURLWithPath: relativePath).pathExtension.lowercased() {
        case "css":
            return "text/css; charset=utf-8"
        case "html":
            return "text/html; charset=utf-8"
        case "js":
            return "application/javascript; charset=utf-8"
        case "json", "map":
            return "application/json; charset=utf-8"
        case "svg":
            return "image/svg+xml; charset=utf-8"
        default:
            return "text/plain; charset=utf-8"
        }
    }

    private static func jsonString(_ payload: Any) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private static func htmlAttribute(_ value: String?) -> String {
        htmlEscaped(value ?? "")
    }

    private static func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static var manifest: String {
        let strings = localizedStrings
        let payload: [String: Any] = [
            "name": strings["appTitle"] ?? "",
            "short_name": strings["productName"] ?? "",
            "start_url": "/remote",
            "scope": "/",
            "display": "standalone",
            "background_color": "#06080a",
            "theme_color": "#06080a",
            "icons": [
                [
                    "src": "/remote/icon.svg",
                    "sizes": "any",
                    "type": "image/svg+xml",
                    "purpose": "any",
                ],
                [
                    "src": "/remote/maskable-icon.svg",
                    "sizes": "any",
                    "type": "image/svg+xml",
                    "purpose": "maskable",
                ],
            ],
        ]
        return jsonString(payload)
    }

    private static var iconSVG: String {
        #"""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128" role="img" aria-label="\#(htmlAttribute(localizedStrings["productName"]))">
  <rect width="128" height="128" rx="28" fill="#06080a"/>
  <path d="M32 42c0-7 6-13 13-13h38c7 0 13 6 13 13v44c0 7-6 13-13 13H45c-7 0-13-6-13-13V42Z" fill="#eef2ea"/>
  <path d="M52 76 39 64l13-12 6 7-6 5 6 5-6 7Zm23 0-6-7 6-5-6-5 6-7 13 12-13 12Z" fill="#06080a"/>
</svg>
"""#
    }
}

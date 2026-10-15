import CmuxControlSocket
import Foundation

extension CMUXCLI {
    /// Usage line for `cmux browser <surface> extension ...`.
    /// Command syntax, not prose, so it is not localized.
    static let browserExtensionUsage =
        "extension <list|load <folder>|enable|disable|remove|reload|pin|unpin|options|run <ext>|move <ext> <index>|command <ext> <name>|webstore|manage>"

    /// Runs `cmux browser <surface> extension ...` (alias `extensions`):
    /// Chrome extension management for a Chromium surface's profile. Verbs
    /// that widen an extension's reach wait for the person to approve a sheet
    /// in the cmux window, so their response timeout covers that wait.
    func runBrowserExtensionCommand(
        surfaceRaw: String?,
        subArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        guard let surfaceRaw,
              let surfaceID = try normalizeSurfaceHandle(surfaceRaw, client: client) else {
            throw CLIError(message: String(
                localized: "cli.browser.extension.error.surfaceRequired",
                defaultValue: "browser extension requires a surface handle (use: browser <surface> extension ...)"
            ))
        }
        let verb = (subArgs.first ?? "list").lowercased()
        let rest = Array(subArgs.dropFirst())
        let request = try browserExtensionRequest(verb: verb, arguments: rest)
        var params = request.params
        params["surface_id"] = surfaceID
        let payload = try client.sendV2(method: request.method, params: params, responseTimeout: request.timeout)
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else if request.method == "browser.extension.list" {
            print(browserExtensionListText(payload))
        } else {
            print("OK")
        }
    }

    /// One parsed `browser extension` invocation.
    struct BrowserExtensionRequest: Equatable {
        var method: String
        var params: [String: String]
        var timeout: TimeInterval
    }

    /// Maps a verb and its arguments to a socket method and params.
    func browserExtensionRequest(verb: String, arguments: [String]) throws -> BrowserExtensionRequest {
        // Consent-gated verbs: the app's sheet waits up to 120 s for the person.
        let consentTimeout: TimeInterval = 130
        let quickTimeout: TimeInterval = 20
        func needs(_ count: Int) throws {
            guard arguments.count == count else {
                throw CLIError(message: String(
                    localized: "cli.browser.extension.error.arguments",
                    defaultValue: "Wrong number of arguments for browser extension. Usage:"
                ) + " cmux browser <surface> " + Self.browserExtensionUsage)
            }
        }
        switch verb {
        case "list", "ls":
            try needs(0)
            return BrowserExtensionRequest(method: "browser.extension.list", params: [:], timeout: quickTimeout)
        case "load", "load-unpacked":
            try needs(1)
            let path = URL(fileURLWithPath: (arguments[0] as NSString).expandingTildeInPath,
                           relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
                .standardizedFileURL.path
            if path.lowercased().hasSuffix(".crx") {
                return BrowserExtensionRequest(method: "browser.extension.install_crx", params: ["path": path],
                                               timeout: quickTimeout)
            }
            return BrowserExtensionRequest(method: "browser.extension.load", params: ["path": path],
                                           timeout: consentTimeout)
        case "enable", "run", "reload":
            try needs(1)
            return BrowserExtensionRequest(method: "browser.extension.\(verb)", params: ["extension": arguments[0]],
                                           timeout: consentTimeout)
        case "disable", "remove", "pin", "unpin", "options":
            try needs(1)
            return BrowserExtensionRequest(method: "browser.extension.\(verb)", params: ["extension": arguments[0]],
                                           timeout: quickTimeout)
        case "move":
            try needs(2)
            guard let index = Int(arguments[1]), index >= 0 else {
                throw CLIError(message: String(
                    localized: "cli.browser.extension.error.index",
                    defaultValue: "browser extension move needs a pinned position (0 or more)"
                ))
            }
            return BrowserExtensionRequest(method: "browser.extension.move",
                                           params: ["extension": arguments[0], "index": String(index)],
                                           timeout: quickTimeout)
        case "command":
            try needs(2)
            return BrowserExtensionRequest(method: "browser.extension.command",
                                           params: ["extension": arguments[0], "command": arguments[1]],
                                           timeout: consentTimeout)
        case "webstore", "manage":
            try needs(0)
            return BrowserExtensionRequest(method: "browser.extension.open_page", params: ["page": verb],
                                           timeout: quickTimeout)
        default:
            throw CLIError(message: String(
                localized: "cli.browser.extension.error.unknownVerb",
                defaultValue: "Unknown browser extension subcommand '\(verb)'. Usage:"
            ) + " cmux browser <surface> " + Self.browserExtensionUsage)
        }
    }

    /// One line per extension: state, pin, name, id and version.
    func browserExtensionListText(_ payload: [String: Any]) -> String {
        let extensions = payload["extensions"] as? [[String: Any]] ?? []
        guard !extensions.isEmpty else {
            return String(localized: "cli.browser.extension.list.empty", defaultValue: "No extensions installed.")
        }
        return extensions.map { item in
            let enabled = (item["enabled"] as? Bool) == true
            let crashed = (item["crashed"] as? Bool) == true
            let state = crashed ? "crashed " : (enabled ? "enabled " : "disabled")
            let pin = (item["pinned"] as? Bool) == true ? "pinned" : "      "
            let name = item["name"] as? String ?? ""
            let id = item["id"] as? String ?? ""
            let version = item["version"] as? String ?? ""
            return "\(state)  \(pin)  \(name)  \(id)\(version.isEmpty ? "" : "  v\(version)")"
        }
        .joined(separator: "\n")
    }
}

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
    /// in the cmux window, so their response timeout covers that wait
    /// (``BrowserExtensionControlRequest``).
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
        let request = try browserExtensionRequest(verb: subArgs.first ?? "", arguments: Array(subArgs.dropFirst()))
        var params: [String: Any] = request.params
        params["surface_id"] = surfaceID
        let payload = try client.sendV2(method: request.method, params: params, responseTimeout: request.responseTimeout)
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else if request.method == "browser.extension.list" {
            print(browserExtensionListText(payload))
        } else {
            print("OK")
        }
    }

    /// Maps a verb and its arguments to a socket request, with localized errors.
    func browserExtensionRequest(verb: String, arguments: [String]) throws -> BrowserExtensionControlRequest {
        do {
            return try BrowserExtensionControlRequest(
                verb: verb, arguments: arguments, currentDirectory: FileManager.default.currentDirectoryPath
            )
        } catch BrowserExtensionControlRequest.ParseError.wrongArgumentCount {
            throw CLIError(message: String(
                localized: "cli.browser.extension.error.arguments",
                defaultValue: "Wrong number of arguments for browser extension. Usage:"
            ) + " cmux browser <surface> " + Self.browserExtensionUsage)
        } catch BrowserExtensionControlRequest.ParseError.invalidIndex {
            throw CLIError(message: String(
                localized: "cli.browser.extension.error.index",
                defaultValue: "browser extension move needs a pinned position (0 or more)"
            ))
        } catch BrowserExtensionControlRequest.ParseError.unknownVerb(let unknown) {
            throw CLIError(message: String(
                localized: "cli.browser.extension.error.unknownVerb",
                defaultValue: "Unknown browser extension subcommand '\(unknown)'. Usage:"
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

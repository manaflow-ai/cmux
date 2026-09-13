import Foundation

extension CMUXCLI {
    /// Runs the browser download wait and history commands. Listing is a
    /// read-only snapshot; waiting keeps the existing timeout and path
    /// behavior for compatibility.
    func runBrowserDownloadCommand(
        surfaceRaw: String?,
        subArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        guard let surfaceRaw,
              let surfaceID = try normalizeSurfaceHandle(surfaceRaw, client: client) else {
            throw CLIError(message: "browser download requires a surface handle")
        }

        switch subArgs.first?.lowercased() {
        case "list", "ls":
            let limit = try parseBrowserDownloadListLimit(Array(subArgs.dropFirst()))
            var params: [String: Any] = ["surface_id": surfaceID]
            if let limit {
                params["limit"] = limit
            }
            let payload = try client.sendV2(
                method: "browser.download.list",
                params: params,
                responseTimeout: 20
            )
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                print(browserDownloadListText(payload))
            }
        default:
            let waitArgs: [String]
            if subArgs.first?.lowercased() == "wait" {
                waitArgs = Array(subArgs.dropFirst())
            } else if let first = subArgs.first,
                      !first.hasPrefix("-"),
                      !browserDownloadLooksLikePath(first) {
                throw CLIError(message: "Unknown browser download subcommand '\(first)'; use 'list' or 'wait'")
            } else {
                waitArgs = subArgs
            }
            let wait = try parseBrowserDownloadWaitArguments(waitArgs)
            var params: [String: Any] = ["surface_id": surfaceID]
            if let path = wait.path {
                params["path"] = path
            }
            if let timeoutMs = wait.timeoutMs {
                params["timeout_ms"] = timeoutMs
            }
            let requestedTimeoutMs = wait.timeoutMs ?? 10_000
            let effectiveTimeoutMs = min(requestedTimeoutMs, 120_000)
            let responseTimeout = Double(max(1, effectiveTimeoutMs)) / 1000.0 + 5.0
            let payload = try client.sendV2(
                method: "browser.download.wait",
                params: params,
                responseTimeout: responseTimeout
            )
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                print("OK")
                if let snapshot = payload["post_action_snapshot"] as? String,
                   !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    print(snapshot)
                }
            }
        }
    }

    private func parseBrowserDownloadListLimit(_ arguments: [String]) throws -> Int? {
        var limit: Int?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let rawValue: String
            if argument == "--limit" {
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    throw CLIError(message: "--limit requires an integer between 1 and 25")
                }
                rawValue = arguments[index + 1]
                index += 2
            } else if argument.hasPrefix("--limit=") {
                rawValue = String(argument.dropFirst("--limit=".count))
                index += 1
            } else {
                throw CLIError(message: "Unexpected argument '\(argument)' for browser download list; use --limit <1...25>")
            }
            guard limit == nil else {
                throw CLIError(message: "browser download list accepts --limit only once")
            }
            guard let value = Int(rawValue), (1...25).contains(value) else {
                throw CLIError(message: "--limit must be an integer between 1 and 25")
            }
            limit = value
        }
        return limit
    }

    private func parseBrowserDownloadWaitArguments(
        _ arguments: [String]
    ) throws -> (path: String?, timeoutMs: Int?) {
        var path: String?
        var timeoutMs: Int?
        var positional: [String] = []
        var index = 0
        var pastTerminator = false
        while index < arguments.count {
            let argument = arguments[index]
            if pastTerminator || argument == "--" {
                pastTerminator = true
                if argument != "--" { positional.append(argument) }
                index += 1
                continue
            }
            if argument == "--path" || argument.hasPrefix("--path=") {
                let value: String
                if argument == "--path" {
                    guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                        throw CLIError(message: "--path requires a destination path")
                    }
                    value = arguments[index + 1]
                    index += 2
                } else {
                    value = String(argument.dropFirst("--path=".count))
                    index += 1
                }
                guard !value.isEmpty, path == nil else {
                    throw CLIError(message: "browser download wait accepts one path")
                }
                path = value
                continue
            }
            if argument == "--timeout-ms" || argument.hasPrefix("--timeout-ms=") {
                let value: String
                if argument == "--timeout-ms" {
                    guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                        throw CLIError(message: "--timeout-ms requires an integer")
                    }
                    value = arguments[index + 1]
                    index += 2
                } else {
                    value = String(argument.dropFirst("--timeout-ms=".count))
                    index += 1
                }
                guard timeoutMs == nil, let parsed = Int(value) else {
                    throw CLIError(message: "--timeout-ms must be an integer")
                }
                timeoutMs = parsed
                continue
            }
            if argument == "--timeout" || argument.hasPrefix("--timeout=") {
                let value: String
                if argument == "--timeout" {
                    guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                        throw CLIError(message: "--timeout requires a number")
                    }
                    value = arguments[index + 1]
                    index += 2
                } else {
                    value = String(argument.dropFirst("--timeout=".count))
                    index += 1
                }
                guard timeoutMs == nil,
                      let seconds = Double(value),
                      seconds.isFinite,
                      seconds * 1000.0 >= Double(Int.min),
                      seconds * 1000.0 <= Double(Int.max) else {
                    throw CLIError(message: "--timeout must be a finite number")
                }
                timeoutMs = max(1, Int(seconds * 1000.0))
                continue
            }
            if argument.hasPrefix("-") {
                throw CLIError(message: "Unknown browser download option '\(argument)'")
            }
            positional.append(argument)
            index += 1
        }
        guard positional.count <= 1, path == nil || positional.isEmpty else {
            throw CLIError(message: "browser download wait accepts one destination path")
        }
        return (path ?? positional.first, timeoutMs)
    }

    private func browserDownloadLooksLikePath(_ value: String) -> Bool {
        value.contains("/")
            || value.hasPrefix("~")
            || value.hasPrefix(".")
            || !URL(fileURLWithPath: value).pathExtension.isEmpty
    }

    private func browserDownloadListText(_ payload: [String: Any]) -> String {
        guard let downloads = payload["downloads"] as? [[String: Any]], !downloads.isEmpty else {
            return "No recent downloads."
        }
        return downloads.enumerated().map { index, download in
            let status = browserDownloadTextValue(download["status"])
            let filename = browserDownloadTextValue(download["filename"])
            let id = browserDownloadTextValue(download["download_id"])
            let path = browserDownloadTextValue(download["path"])
            let bytes = browserDownloadTextValue(download["bytes"])
            let pathExists = browserDownloadTextValue(download["path_exists"])
            return [
                "\(index + 1). \(status) \(filename)",
                "   id: \(id)",
                "   path: \(path)",
                "   bytes: \(bytes)",
                "   path_exists: \(pathExists)",
            ].joined(separator: "\n")
        }.joined(separator: "\n")
    }

    private func browserDownloadTextValue(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "<unavailable>" }
        let text = BrowserValueTextFormatter().string(from: value)
        return text.unicodeScalars.map { scalar in
            switch scalar.value {
            case 9: return "\\t"
            case 10: return "\\n"
            case 13: return "\\r"
            case 0...31, 127:
                let hex = String(scalar.value, radix: 16, uppercase: true)
                let padded = String(repeating: "0", count: max(0, 4 - hex.count)) + hex
                return "\\u{\(padded)}"
            default: return String(scalar)
            }
        }.joined()
    }
}

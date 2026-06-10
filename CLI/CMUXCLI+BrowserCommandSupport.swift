import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif

// MARK: - Browser command support helpers

/// Carries the state `runBrowserCommand`'s prologue computes and that the
/// per-family subcommand handlers (plus their shared helpers) previously
/// closed over as nested-function captures inside one 1600-line function.
///
/// A `final class` preserves the original shared-storage capture semantics:
/// every family handler observes the same instance the dispatcher built.
/// All properties are `let` because the original locals were only mutated in
/// the prologue, before any helper or dispatch block ran (no dispatch block
/// writes `effectiveJSONOutput`, `effectiveIDFormat`, or `surfaceRaw`).
final class BrowserCommandContext {
    let cli: CMUXCLI
    let client: SocketClient
    let subcommand: String
    let subArgs: [String]
    let surfaceRaw: String?
    let effectiveJSONOutput: Bool
    let effectiveIDFormat: CLIIDFormat

    init(
        cli: CMUXCLI,
        client: SocketClient,
        subcommand: String,
        subArgs: [String],
        surfaceRaw: String?,
        effectiveJSONOutput: Bool,
        effectiveIDFormat: CLIIDFormat
    ) {
        self.cli = cli
        self.client = client
        self.subcommand = subcommand
        self.subArgs = subArgs
        self.surfaceRaw = surfaceRaw
        self.effectiveJSONOutput = effectiveJSONOutput
        self.effectiveIDFormat = effectiveIDFormat
    }

    func requireSurface() throws -> String {
        guard let raw = surfaceRaw else {
            throw CLIError(message: "browser \(subcommand) requires a surface handle (use: browser <surface> \(subcommand) ... or --surface)")
        }
        guard let resolved = try cli.normalizeSurfaceHandle(raw, client: client) else {
            throw CLIError(message: "Invalid surface handle")
        }
        return resolved
    }

    func output(_ payload: [String: Any], fallback: String) {
        if effectiveJSONOutput {
            print(cli.jsonString(cli.formatIDs(payload, mode: effectiveIDFormat)))
            return
        }
        print(fallback)
        if let snapshot = payload["post_action_snapshot"] as? String,
           !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print(snapshot)
        }
    }

    func displaySnapshotText(_ payload: [String: Any]) -> String {
        let snapshotText = (payload["snapshot"] as? String) ?? "Empty page"
        guard snapshotText.contains("\n- (empty)") else {
            return snapshotText
        }

        let url = ((payload["url"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let readyState = ((payload["ready_state"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = [snapshotText]

        if !url.isEmpty {
            lines.append("url: \(url)")
        }
        if !readyState.isEmpty {
            lines.append("ready_state: \(readyState)")
        }
        if url.isEmpty || url == "about:blank" {
            lines.append("hint: run 'cmux browser <surface> get url' to verify navigation")
        }

        return lines.joined(separator: "\n")
    }

    func displayBrowserValue(_ value: Any) -> String {
        if let dict = value as? [String: Any],
           let type = dict["__cmux_t"] as? String,
           type == "undefined" {
            return "undefined"
        }
        if value is NSNull {
            return "null"
        }
        if let string = value as? String {
            return string
        }
        if let bool = value as? Bool {
            return bool ? "true" : "false"
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: value)
    }

    func displayBrowserLogItems(_ value: Any?) -> String? {
        guard let items = value as? [Any], !items.isEmpty else {
            return nil
        }

        let lines = items.map { item -> String in
            guard let dict = item as? [String: Any] else {
                return displayBrowserValue(item)
            }

            let text = (dict["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let levelRaw = (dict["level"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let level = levelRaw.isEmpty ? "log" : levelRaw

            if text.isEmpty {
                if let message = (dict["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !message.isEmpty {
                    return "[error] \(message)"
                }
                return displayBrowserValue(dict)
            }
            return "[\(level)] \(text)"
        }

        return lines.joined(separator: "\n")
    }

    func nonFlagArgs(_ values: [String]) -> [String] {
        values.filter { !$0.hasPrefix("-") }
    }

    func optionValues(_ values: [String], names: Set<String>) throws -> [String] {
        var result: [String] = []
        var index = 0
        while index < values.count {
            let value = values[index]
            if names.contains(value) {
                guard index + 1 < values.count,
                      !values[index + 1].hasPrefix("-"),
                      !names.contains(values[index + 1]) else {
                    throw CLIError(message: "\(value) requires a value")
                }
                result.append(values[index + 1])
                index += 2
                continue
            }
            index += 1
        }
        return result
    }

    func firstOptionValue(_ values: [String], names: Set<String>) throws -> String? {
        try optionValues(values, names: names).first
    }

    func intPayloadValue(_ value: Any?) -> Int {
        if let intValue = value as? Int { return intValue }
        if let number = value as? NSNumber { return number.intValue }
        return 0
    }

    func stringPayloadValue(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func browserProfileLine(_ raw: Any) -> String? {
        guard let profile = raw as? [String: Any],
              let name = stringPayloadValue(profile["name"]),
              let slug = stringPayloadValue(profile["slug"]),
              let id = stringPayloadValue(profile["id"]) else {
            return nil
        }
        var markers: [String] = []
        if (profile["current"] as? Bool) == true {
            markers.append("current")
        }
        if (profile["built_in_default"] as? Bool) == true {
            markers.append("default")
        }
        let suffix = markers.isEmpty ? "" : " (\(markers.joined(separator: ", ")))"
        return "\(slug)\t\(name)\t\(id)\(suffix)"
    }

    func printBrowserProfiles(_ payload: [String: Any]) {
        guard let profiles = payload["profiles"] as? [Any], !profiles.isEmpty else {
            print("No browser profiles")
            return
        }
        for profile in profiles {
            if let line = browserProfileLine(profile) {
                print(line)
            }
        }
    }
}

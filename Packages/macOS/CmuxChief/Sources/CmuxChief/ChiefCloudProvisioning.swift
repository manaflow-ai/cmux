public import CmuxHomeCore
import Foundation

/// The Chief's Cloud machine provisioning as one updating work row.
///
/// Creating a machine is two or more tool calls (`cmux vm new --detach
/// --json`, then `cmux vm wait <machine>`, maybe a retry). Shown as tool
/// lines they read as a stream of commands; the owner instead keeps one work
/// message per turn ("Creating cloud machine… 40 s", then "Ready") and maps
/// every provisioning call onto it (``ChiefConversationOwner``'s
/// `toolStarted`). Clients recognize the row by its session prefix
/// (``sessionPrefix``) and draw elapsed time from the message's `createdAt`;
/// `host` is the machine id once `vm new` printed it and `preview` its display
/// name (``machineName(inCommand:)``, ``machineName(inOutput:)``) while the row
/// has not failed (a failure's preview is the output).
///
/// A `vm new` that waits for the user's approval does not time anything yet:
/// its card takes the row's place, and an Allow posts the row again, so
/// "Creating cloud machine…" counts from when the command really runs
/// (`ChiefConversationOwner+Provisioning.swift`).
///
/// A value is one provisioning step (``phase(ofCommand:)``).
public enum ChiefCloudProvisioning: Sendable, Equatable {
    /// `cmux vm new` (or `vm route --provision`): the machine is being created.
    case create
    /// `cmux vm wait <machine>`: waiting for it to become ready.
    case wait

    /// The row's `WorkRef.session` prefix; clients key their rendering on it.
    public static let sessionPrefix = "chief.provision:"
    /// The row's stored title (search, notifications, clients without the row).
    public static let title = "Cloud machine"

    /// Whether `work` is a provisioning row.
    public static func isProvisioning(_ work: WorkRef) -> Bool { work.session.hasPrefix(sessionPrefix) }

    /// The provisioning step a shell command performs, nil for other commands.
    ///
    /// Matches `cmux vm|cloud new …`, `cmux vm|cloud wait …` and
    /// `cmux vm|cloud route … --provision` as a pipeline stage, so
    /// `cmux vm new --detach --json` and `cd x && cmux vm wait m` both count;
    /// `cmux vm new --help` does not.
    public static func phase(ofCommand command: String) -> ChiefCloudProvisioning? {
        let words = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var index = 0
        while index < words.count {
            defer { index += 1 }
            guard words[index].hasSuffix("cmux"), index + 2 < words.count,
                  ["vm", "cloud"].contains(words[index + 1]) else { continue }
            let rest = words[(index + 3)...].prefix { !["&&", "||", ";", "|"].contains($0) }
            if rest.contains("--help") || rest.contains("-h") { return nil }
            switch words[index + 2] {
            case "new": return .create
            case "wait": return .wait
            case "route" where rest.contains("--provision"): return .create
            default: continue
            }
        }
        return nil
    }

    /// The machine id in `vm new --json` output (`"id": "brave-otter"`), or
    /// the `<id> is ready` line `--detach` prints.
    public static func machine(inOutput output: String?) -> String? {
        guard let output, !output.isEmpty else { return nil }
        return capture(#""id"\s*:\s*"([^"\s]+)""#, in: output) ?? capture(#"(?m)^(\S+) is ready"#, in: output)
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// The machine's display name: `--name <name>` (or `--name=<name>`) on a `vm new` command.
    /// The row shows it ("chief-dogfood-1"); the id stays in `host` (its tooltip).
    public static func machineName(inCommand command: String) -> String? {
        let words = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for (offset, word) in words.enumerated() {
            if word.hasPrefix("--name=") { return unquoted(String(word.dropFirst("--name=".count))) }
            if word == "--name" { return words.dropFirst(offset + 1).first.flatMap(unquoted) }
        }
        return nil
    }

    /// The machine's display name in `vm new --json` output: the backend answers
    /// `"displayName"` (older payloads `"display_name"` or `"name"`).
    public static func machineName(inOutput output: String?) -> String? {
        guard let output, !output.isEmpty else { return nil }
        for key in ["displayName", "display_name", "name"] {
            if let name = capture(#""\#(key)"\s*:\s*"([^"]+)""#, in: output).flatMap(unquoted) { return name }
        }
        return nil
    }

    private static func unquoted(_ word: String) -> String? {
        let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "'\"").union(.whitespaces))
        return trimmed.isEmpty || trimmed.hasPrefix("-") ? nil : trimmed
    }

    /// The machine a `vm wait <machine>` command names.
    public static func machine(inCommand command: String) -> String? {
        let words = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let wait = words.firstIndex(of: "wait"), wait + 1 < words.count, !words[wait + 1].hasPrefix("-") else { return nil }
        return words[wait + 1]
    }
}

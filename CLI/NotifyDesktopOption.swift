import Foundation

/// `cmux notify --desktop <true|false>`: whether the notification posts a native
/// macOS banner. `--desktop=<value>` and `--no-desktop` are accepted spellings.
/// Absent means the notification keeps the policy default.
///
/// Shared by the CLI and its unit tests, so the parser is pure over the argument
/// list and reports failures as values.
enum NotifyDesktopOption {
    struct ParseError: Error, Equatable {
        let message: String
    }

    static func parse(_ args: [String]) throws -> Bool? {
        var requested: Bool?
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--" { break }
            var raw: String?
            if arg == "--desktop" {
                guard index + 1 < args.count else { throw ParseError(message: valueMessage) }
                index += 1
                raw = args[index]
            } else if arg.hasPrefix("--desktop=") {
                raw = String(arg.dropFirst("--desktop=".count))
            } else if arg == "--no-desktop" {
                raw = "false"
            }
            if let raw {
                guard let value = parseBool(raw) else { throw ParseError(message: valueMessage) }
                if let requested, requested != value { throw ParseError(message: conflictMessage) }
                requested = value
            }
            index += 1
        }
        return requested
    }

    /// The same spellings every other boolean flag accepts.
    private static func parseBool(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    private static var valueMessage: String {
        String(
            localized: "cli.error.notifyDesktopValue",
            defaultValue: "notify --desktop takes true or false"
        )
    }

    private static var conflictMessage: String {
        String(
            localized: "cli.error.notifyDesktopConflict",
            defaultValue: "notify: --desktop and --no-desktop disagree; pass one of them"
        )
    }
}

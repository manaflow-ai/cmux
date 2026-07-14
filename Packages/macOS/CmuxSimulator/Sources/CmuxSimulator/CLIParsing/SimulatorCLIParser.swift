internal import Foundation

/// Parses the argument vector of the `cmux simulator` namespace.
///
/// Lexical parsing only: handles (`--workspace`, `--window`, `--surface`) stay
/// raw strings here and are normalized against the live socket by the CLI
/// shell. Lives in this package so argument handling is unit-testable with
/// plain `swift test` (the CLI target has no test bundle of its own).
///
/// ```swift
/// let request = try SimulatorCLIParser().parse(
///     ["open", "--device", "iPhone 17 Pro", "--focus", "false"]
/// )
/// ```
public struct SimulatorCLIParser: Sendable {
    /// Creates a parser.
    public init() {}

    /// Parses the arguments following `cmux simulator`.
    ///
    /// - Parameter arguments: The raw argument vector after the namespace token.
    /// - Returns: The parsed request.
    /// - Throws: ``SimulatorCLIParseError`` with a printable usage message.
    public func parse(_ arguments: [String]) throws -> SimulatorCLIRequest {
        var subcommand: String?
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            index += 1
            if token == "--help" || token == "-h" || token == "help" {
                return .help
            }
            if token == "--json" {
                // The CLI shell's global output flag; not this namespace's concern.
                continue
            }
            if token.hasPrefix("--") {
                let name = String(token.dropFirst(2))
                guard Self.knownOptionNames.contains(name) else {
                    throw SimulatorCLIParseError(message: "Unknown simulator option: \(token). \(Self.tryHelp)")
                }
                guard index < arguments.count else {
                    throw SimulatorCLIParseError(message: "Missing value for --\(name). \(Self.tryHelp)")
                }
                options[name] = arguments[index]
                index += 1
                continue
            }
            guard subcommand == nil else {
                throw SimulatorCLIParseError(message: "Unexpected argument: \(token). \(Self.tryHelp)")
            }
            subcommand = token
        }

        switch subcommand?.lowercased() {
        case nil:
            return .help
        case "list", "ls":
            try requireOnly([], options: options, subcommand: "list")
            return .list
        case "open":
            try requireOnly(["device", "workspace", "window", "focus"], options: options, subcommand: "open")
            guard let device = options["device"], !device.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw SimulatorCLIParseError(
                    message: "Usage: cmux simulator open --device <name|udid> [--workspace <id|ref|index>] [--focus true|false]"
                )
            }
            return .open(SimulatorCLIOpenRequest(
                deviceQuery: device,
                workspace: options["workspace"],
                window: options["window"],
                focus: try focusValue(options["focus"])
            ))
        case "close":
            try requireOnly(["surface", "workspace", "window"], options: options, subcommand: "close")
            return .close(SimulatorCLICloseRequest(
                surface: options["surface"],
                workspace: options["workspace"],
                window: options["window"]
            ))
        case .some(let other):
            throw SimulatorCLIParseError(
                message: "Unknown simulator subcommand: \(other). Try: list, open, close"
            )
        }
    }

    private static let knownOptionNames: Set<String> = [
        "device", "workspace", "window", "focus", "surface",
    ]

    private static let tryHelp = "Try: cmux simulator --help"

    private func requireOnly(
        _ allowed: Set<String>,
        options: [String: String],
        subcommand: String
    ) throws {
        if let stray = options.keys.first(where: { !allowed.contains($0) }) {
            throw SimulatorCLIParseError(
                message: "simulator \(subcommand) does not take --\(stray). \(Self.tryHelp)"
            )
        }
    }

    private func focusValue(_ raw: String?) throws -> Bool {
        guard let raw else { return false }
        switch raw.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default:
            throw SimulatorCLIParseError(message: "--focus must be true or false")
        }
    }
}

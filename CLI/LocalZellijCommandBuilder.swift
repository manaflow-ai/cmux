import Foundation

/// Validates names before they become zellij session names and socket files.
struct LocalZellijSessionNameValidator {
    /// Longest name whose socket path still fits `sockaddr_un`. zellij hangs
    /// instead of failing when its socket path is too long, so reject early.
    let maxNameBytes: Int

    func validate(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading dash would reach zellij as an option, not a session name.
        guard !name.isEmpty,
              name.utf8.count <= min(128, maxNameBytes),
              name.range(of: "^[A-Za-z0-9_][A-Za-z0-9_-]*$", options: .regularExpression) != nil else {
            throw CLIError(message: String(localized: "cli.localZellij.error.invalidName", defaultValue: "local-zellij session names must start with a letter, number, or underscore, contain only letters, numbers, underscores, or dashes, and be short enough for a Unix socket path"))
        }
        return name
    }
}

/// Builds zellij invocations for cmux's opt-in local-zellij profile.
///
/// Every invocation points `ZELLIJ_SOCKET_DIR` at a private directory, so the
/// live sessions visible to this profile are the ones it started. Every client
/// attaches with `--on-force-close detach`: zellij applies that option on the
/// client, so closing or killing a cmux surface detaches instead of quitting
/// the session even when the user's zellij config says `quit`.
struct LocalZellijCommandBuilder {
    static let restoreMarker = "CMUX_LOCAL_ZELLIJ=1"
    static let socketDirectoryVariable = "ZELLIJ_SOCKET_DIR"
    /// `sockaddr_un.sun_path` on macOS holds 104 bytes including the NUL.
    static let maxSocketPathBytes = 103
    /// Room for the per-release directory zellij creates inside the socket
    /// directory (`0.43.1/`, `contract_version_1/`, ...).
    static let releaseDirectoryAllowance = 24
    /// `-` plus eight hex digits appended by `zellijSessionName(for:)`.
    static let ownershipTokenBytes = 9

    let zellijPath: String
    let socketDirectory: String

    /// Longest name a user can give a session, after reserving room for the
    /// release directory and the ownership token.
    var maxSessionNameBytes: Int {
        Self.maxSocketPathBytes - socketDirectory.utf8.count - 1
            - Self.releaseDirectoryAllowance - Self.ownershipTokenBytes
    }

    /// The zellij session behind a registry record: the user's name plus a
    /// token from the record's UUID. zellij lists exited sessions from a cache
    /// shared with the user's other zellij sessions, so a bare name cannot show
    /// that a listed session was started by this profile; the token can.
    static func zellijSessionName(for record: LocalTmuxSessionRecord) -> String {
        "\(record.name)-\(record.id.uuidString.prefix(8).lowercased())"
    }

    /// The shell command a cmux surface runs, and the only one session
    /// restore will replay for this profile.
    func attachCommand(sessionName: String) -> String {
        // Ghostty evaluates a shell command as `exec -l <command>`; `env`
        // carries the socket directory and restore marker into zellij.
        let arguments = attachArguments(sessionName: sessionName).map(shellQuote).joined(separator: " ")
        return "/usr/bin/env \(Self.socketDirectoryVariable)=\(shellQuote(socketDirectory)) \(Self.restoreMarker) \(shellQuote(zellijPath)) \(arguments)"
    }

    func attachArguments(sessionName: String) -> [String] {
        ["attach", sessionName, "options", "--on-force-close", "detach"]
    }

    func createBackgroundArguments(
        sessionName: String,
        workingDirectory: String,
        layoutPath: String?
    ) -> [String] {
        var arguments = [
            "attach", "--create-background", sessionName,
            "options", "--default-cwd", workingDirectory,
            "--on-force-close", "detach",
            // Only this CLI's sanitized runner may start a zellij server.
            // A serialized session outlives its server, and a surface's
            // `zellij attach` would resurrect it into a new server that
            // inherits the surface's CMUX_* credentials and identity.
            "--session-serialization", "false",
        ]
        if let layoutPath {
            arguments.append(contentsOf: ["--default-layout", layoutPath])
        }
        return arguments
    }

    func listSessionsArguments() -> [String] {
        ["list-sessions", "--no-formatting"]
    }

    /// Kills a live session and removes its resurrection entry, so a closed
    /// session cannot come back on a later attach.
    func deleteSessionArguments(sessionName: String) -> [String] {
        ["delete-session", "--force", sessionName]
    }

    /// Environment for zellij processes started by the CLI. The caller's own
    /// session markers are dropped; config variables such as
    /// `ZELLIJ_CONFIG_FILE` are kept so the user's config still applies.
    func environment(base: [String: String]) -> [String: String] {
        var environment = base
        for key in ["ZELLIJ", "ZELLIJ_SESSION_NAME", "ZELLIJ_PANE_ID"] {
            environment.removeValue(forKey: key)
        }
        environment[Self.socketDirectoryVariable] = socketDirectory
        return environment
    }

    /// A layout matching zellij's default one (tab bar, one pane, status
    /// bar) whose pane runs `command` through a login shell. A layout is used
    /// because `zellij run` in a session with no client opens a floating pane.
    func commandLayout(command: String) -> String {
        """
        layout {
            pane size=1 borderless=true {
                plugin location="zellij:tab-bar"
            }
            pane command="/bin/sh" {
                args "-lc" \(kdlString(command))
            }
            pane size=2 borderless=true {
                plugin location="zellij:status-bar"
            }
        }

        """
    }

    private func kdlString(_ value: String) -> String {
        var escaped = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if scalar.properties.generalCategory == .control {
                    escaped += String(format: "\\u{%x}", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return escaped + "\""
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Parses `zellij list-sessions --no-formatting` output.
struct LocalZellijSessionListParser {
    struct Session: Equatable {
        let name: String
        /// A serialized session that `zellij attach` would resurrect.
        let exited: Bool
    }

    private static let emptyListingMessage = "No active zellij sessions found"

    /// Returns `nil` when the listing failed and liveness is unknown.
    func sessions(_ result: LocalTmuxProcessResult) -> [Session]? {
        guard !result.outputWasTruncated else { return nil }
        guard result.succeeded else {
            // zellij exits 1 with this message when nothing is listed.
            return result.stderr.contains(Self.emptyListingMessage) ? [] : nil
        }
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                guard let marker = line.range(of: " [Created ") else { return nil }
                let name = String(line[..<marker.lowerBound])
                guard !name.isEmpty else { return nil }
                return Session(name: name, exited: line[marker.upperBound...].contains("(EXITED"))
            }
    }
}

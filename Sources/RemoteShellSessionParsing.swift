import Foundation
import Darwin

enum RemoteShellTransport: Sendable {
    case ssh
    case eternalTerminal

    init?(executableName: String) {
        switch RemoteShellSessionParsing.normalizedExecutableName(executableName) {
        case "ssh":
            self = .ssh
        case "et":
            self = .eternalTerminal
        default:
            return nil
        }
    }

    var executableName: String {
        switch self {
        case .ssh:
            return "ssh"
        case .eternalTerminal:
            return "et"
        }
    }
}

enum RemoteShellSessionParsing {
    private static let eternalTerminalNoArgumentFlags = Set("efhNx")
    private static let eternalTerminalValueArgumentFlags = Set("cklprtu")
    private static let eternalTerminalLongValueOptions: Set<String> = [
        "command",
        "host",
        "jport",
        "jserverfifo",
        "jumphost",
        "keepalive",
        "logdir",
        "port",
        "reversetunnel",
        "serverfifo",
        "ssh-socket",
        "terminal-path",
        "tunnel",
        "username",
    ]
    private static let eternalTerminalLongNoArgumentOptions: Set<String> = [
        "forward-ssh-agent",
        "help",
        "kill-other-sessions",
        "logtostdout",
        "macserver",
        "no-terminal",
        "noexit",
        "silent",
        "version",
    ]
    private static let filteredSSHOptionKeys: Set<String> = [
        "batchmode",
        "controlmaster",
        "controlpersist",
        "forkafterauthentication",
        "localcommand",
        "permitlocalcommand",
        "remotecommand",
        "requesttty",
        "sendenv",
        "sessiontype",
        "setenv",
        "stdioforward",
    ]

    static func normalizedExecutableName(_ executableName: String) -> String {
        let trimmed = executableName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.split(separator: "/").last.map(String.init)?.lowercased() ?? trimmed.lowercased()
    }

    static func parseEternalTerminalCommandLine(_ arguments: [String]) -> DetectedSSHSession? {
        guard !arguments.isEmpty else { return nil }

        var index = 0
        if normalizedExecutableName(arguments[0]) == RemoteShellTransport.eternalTerminal.executableName {
            index = 1
        }

        var destination: String?
        var port: Int?
        var identityFile: String?
        let configFile: String? = nil
        var jumpHost: String?
        var controlPath: String?
        var loginName: String?
        let useIPv4 = false
        let useIPv6 = false
        var forwardAgent = false
        let compressionEnabled = false
        var sshOptions: [String] = []

        func consumeSSHOptionValue(_ value: String) -> Bool {
            consumeSSHOption(
                value,
                port: &port,
                identityFile: &identityFile,
                controlPath: &controlPath,
                jumpHost: &jumpHost,
                loginName: &loginName,
                sshOptions: &sshOptions
            )
        }

        func consumeETValue(_ value: String, for option: String) -> Bool {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty else { return false }

            switch option {
            case "host":
                destination = trimmedValue
            case "jumphost":
                let resolvedJumpHost = resolveEternalTerminalDestination(trimmedValue, loginName: nil)
                guard !resolvedJumpHost.isEmpty else { return false }
                jumpHost = resolvedJumpHost
            case "jport", "keepalive", "port":
                guard Int(trimmedValue) != nil else { return false }
            case "username":
                loginName = trimmedValue
            default:
                break
            }
            return true
        }

        func consumeETValue(_ value: String, for option: Character) -> Bool {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty else { return false }

            switch option {
            case "k", "p":
                return Int(trimmedValue) != nil
            case "u":
                return consumeETValue(trimmedValue, for: "username")
            default:
                return true
            }
        }

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                let nextIndex = index + 1
                if nextIndex < arguments.count, destination == nil {
                    destination = arguments[nextIndex]
                }
                break
            }
            if !argument.hasPrefix("-") || argument == "-" {
                if destination == nil {
                    destination = argument
                }
                break
            }

            if argument == "--ssh-option" {
                let nextIndex = index + 1
                guard nextIndex < arguments.count,
                      consumeSSHOptionValue(arguments[nextIndex]) else {
                    return nil
                }
                index += 2
                continue
            }
            if argument.hasPrefix("--ssh-option=") {
                let value = String(argument.dropFirst("--ssh-option=".count))
                guard consumeSSHOptionValue(value) else { return nil }
                index += 1
                continue
            }

            if argument.hasPrefix("--") {
                let optionText = String(argument.dropFirst(2))
                let parts = optionText.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let optionName = String(parts[0])

                if optionName == "forward-ssh-agent" {
                    forwardAgent = true
                    index += 1
                    continue
                }
                if optionName == "telemetry" {
                    if parts.count == 1, index + 1 < arguments.count, isBoolLiteral(arguments[index + 1]) {
                        index += 2
                    } else {
                        index += 1
                    }
                    continue
                }
                if optionName == "verbose" {
                    if parts.count == 2 {
                        guard Int(String(parts[1])) != nil else { return nil }
                    } else if index + 1 < arguments.count, Int(arguments[index + 1]) != nil {
                        index += 1
                    }
                    index += 1
                    continue
                }
                if eternalTerminalLongValueOptions.contains(optionName) {
                    if parts.count == 2 {
                        guard consumeETValue(String(parts[1]), for: optionName) else { return nil }
                        index += 1
                    } else {
                        let nextIndex = index + 1
                        guard nextIndex < arguments.count,
                              consumeETValue(arguments[nextIndex], for: optionName) else {
                            return nil
                        }
                        index += 2
                    }
                    continue
                }
                if eternalTerminalLongNoArgumentOptions.contains(optionName) || parts.count == 2 {
                    index += 1
                    continue
                }
                return nil
            }

            let shortOptions = Array(argument.dropFirst())
            guard let option = shortOptions.first else { return nil }
            if option == "f" {
                forwardAgent = true
                guard shortOptions.count == 1 else { return nil }
                index += 1
                continue
            }
            if option == "v" {
                if shortOptions.count > 1 {
                    guard Int(String(argument.dropFirst(2))) != nil else { return nil }
                    index += 1
                } else if index + 1 < arguments.count, Int(arguments[index + 1]) != nil {
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            if eternalTerminalValueArgumentFlags.contains(option) {
                if shortOptions.count > 1 {
                    guard consumeETValue(String(argument.dropFirst(2)), for: option) else { return nil }
                    index += 1
                } else {
                    let nextIndex = index + 1
                    guard nextIndex < arguments.count,
                          consumeETValue(arguments[nextIndex], for: option) else {
                        return nil
                    }
                    index += 2
                }
                continue
            }
            guard shortOptions.allSatisfy({ eternalTerminalNoArgumentFlags.contains($0) }) else {
                return nil
            }
            index += 1
        }

        guard let destination else { return nil }
        let finalDestination = resolveEternalTerminalDestination(destination, loginName: loginName)
        guard !finalDestination.isEmpty else { return nil }

        return DetectedSSHSession(
            destination: finalDestination,
            port: port,
            identityFile: identityFile,
            configFile: configFile,
            jumpHost: jumpHost,
            controlPath: controlPath,
            useIPv4: useIPv4,
            useIPv6: useIPv6,
            forwardAgent: forwardAgent,
            compressionEnabled: compressionEnabled,
            sshOptions: sshOptions
        )
    }

    static func consumeSSHOption(
        _ option: String,
        port: inout Int?,
        identityFile: inout String?,
        controlPath: inout String?,
        jumpHost: inout String?,
        loginName: inout String?,
        sshOptions: inout [String]
    ) -> Bool {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let key = sshOptionKey(trimmed)
        let value = sshOptionValue(trimmed)

        switch key {
        case "port":
            if let value, let parsedPort = Int(value) {
                port = parsedPort
                return true
            }
            return false
        case "identityfile":
            if let value, !value.isEmpty {
                identityFile = value
                return true
            }
            return false
        case "controlpath":
            if let value, !value.isEmpty {
                controlPath = value
                return true
            }
            return false
        case "proxyjump":
            if let value, !value.isEmpty {
                jumpHost = value
                return true
            }
            return false
        case "user":
            if let value, !value.isEmpty {
                loginName = value
                return true
            }
            return false
        case let key? where filteredSSHOptionKeys.contains(key):
            return true
        case .some, .none:
            sshOptions.append(trimmed)
            return true
        }
    }

    static func resolveDestination(_ destination: String, loginName: String?) -> String {
        let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDestination.isEmpty else { return "" }
        guard let loginName = loginName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !loginName.isEmpty,
              !trimmedDestination.contains("@") else {
            return trimmedDestination
        }
        return "\(loginName)@\(trimmedDestination)"
    }

    private static func resolveEternalTerminalDestination(_ destination: String, loginName: String?) -> String {
        let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDestination.isEmpty else { return "" }

        let parts = trimmedDestination.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            let user = String(parts[0])
            let host = stripEternalTerminalServerPort(fromHost: String(parts[1]))
            guard !user.isEmpty, !host.isEmpty else { return "" }
            return "\(user)@\(host)"
        }

        let host = stripEternalTerminalServerPort(fromHost: trimmedDestination)
        return resolveDestination(host, loginName: loginName)
    }

    private static func stripEternalTerminalServerPort(fromHost host: String) -> String {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return "" }

        if trimmedHost.hasPrefix("["),
           let closingBracket = trimmedHost.firstIndex(of: "]") {
            let hostStart = trimmedHost.index(after: trimmedHost.startIndex)
            let bracketedHost = String(trimmedHost[hostStart..<closingBracket])
            let remainderStart = trimmedHost.index(after: closingBracket)
            let remainder = trimmedHost[remainderStart...]
            if remainder.hasPrefix(":") {
                let portStart = remainder.index(after: remainder.startIndex)
                let port = remainder[portStart...]
                if Int(port) != nil {
                    return "[\(bracketedHost)]"
                }
            }
            return trimmedHost
        }

        let colonCount = trimmedHost.reduce(0) { count, character in
            character == ":" ? count + 1 : count
        }
        guard let lastColon = trimmedHost.lastIndex(of: ":") else {
            return trimmedHost
        }

        let portStart = trimmedHost.index(after: lastColon)
        let port = trimmedHost[portStart...]
        guard Int(port) != nil else { return trimmedHost }
        let strippedHost = String(trimmedHost[..<lastColon])
        if colonCount == 1 {
            return strippedHost
        }
        if colonCount == 8 && !trimmedHost.contains("::") {
            return "[\(strippedHost)]"
        }
        // Compressed IPv6 with a trailing decimal hextet is ambiguous; preserve it as a host.
        return trimmedHost
    }

    private static func isIPv6Literal(_ host: String) -> Bool {
        var address = in6_addr()
        return host.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
    }

    private static func isBoolLiteral(_ value: String) -> Bool {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "0", "1", "false", "no", "true", "yes":
            return true
        default:
            return false
        }
    }

    private static func sshOptionKey(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }

    private static func sshOptionValue(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let equalIndex = trimmed.firstIndex(of: "=") {
            let value = trimmed[trimmed.index(after: equalIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.count == 2 else { return nil }
        let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

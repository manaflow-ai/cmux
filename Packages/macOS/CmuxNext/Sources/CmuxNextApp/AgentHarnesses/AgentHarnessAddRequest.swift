import Foundation

/// `agent.harness.add`'s fields, as `_acpmux/harness/add` takes them.
struct AgentHarnessAddRequest: Equatable {
    var id: String?
    var displayName: String?
    var command: String?
    var args: [String] = []
    var protocolName: String?
    var registry: String?
    var example: String?
    /// Env keys the profile reads from Keychain items of the same name (`keychain:KEY`), never values.
    var envKeys: [String] = []
    var replace = false

    /// Nil when it names nothing to start: no command, registry agent or example.
    var isComplete: Bool { [command, registry, example].contains { !($0 ?? "").isEmpty } }

    var params: [String: any Sendable] {
        var params: [String: any Sendable] = [:]
        if let id, !id.isEmpty { params["id"] = id }
        if let displayName, !displayName.isEmpty { params["displayName"] = displayName }
        if let command, !command.isEmpty {
            params["command"] = command
            // The daemon takes args and env only with a command.
            if !args.isEmpty { params["args"] = args }
            // A key names a Keychain item (`cmux harness secret set`); the value never passes here.
            if !envKeys.isEmpty { params["env"] = Dictionary(uniqueKeysWithValues: envKeys.map { ($0, "keychain:\($0)") }) }
        }
        if let protocolName, !protocolName.isEmpty { params["protocol"] = protocolName }
        if let registry, !registry.isEmpty { params["registry"] = registry }
        if let example, !example.isEmpty { params["example"] = example }
        if replace { params["replace"] = true }
        return params
    }

    /// Splits a typed argument line the way a shell would for plain words and quotes.
    static func words(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var started = false
        for character in line {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                started = true
            } else if character.isWhitespace {
                if started || !current.isEmpty { words.append(current) }
                current = ""
                started = false
            } else {
                current.append(character)
            }
        }
        if started || !current.isEmpty { words.append(current) }
        return words
    }
}

enum AgentHarnessFailure: Error, Equatable {
    /// No local acpmux (a mock agent host, or no binary).
    case noDaemon
    /// The daemon predates the harness operations.
    case unsupported

    var message: String {
        switch self {
        case .noDaemon: AgentHarnessStrings.noDaemon
        case .unsupported: AgentHarnessStrings.unsupported
        }
    }
}

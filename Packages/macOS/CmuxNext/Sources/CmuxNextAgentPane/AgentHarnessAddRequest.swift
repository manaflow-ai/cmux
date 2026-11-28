/// `agent.harness.add`'s fields, as `_acpmux/harness/add` takes them.
package nonisolated struct AgentHarnessAddRequest: Equatable {
    package var id: String?
    package var displayName: String?
    package var command: String?
    package var args: [String] = []
    package var protocolName: String?
    package var registry: String?
    package var example: String?
    /// Env keys the profile reads from Keychain items of the same name (`keychain:KEY`), never values.
    package var envKeys: [String] = []
    /// An endpoint profile (`example: anthropic-endpoint|openai-endpoint`): its base URL, model and
    /// key, which acpmux stores in the profile's own Keychain item in the same locked add.
    package var baseURL: String?
    package var model: String?
    package var apiKey: String?
    package var replace = false
    package var editEndpoint: String?
    package var endpointPreset: String?
    package var servesCloud: Bool?
    package var validateEndpoint: Bool = false

    package init() {}

    /// Nil when it names nothing to start: no command, registry agent or example.
    package var isComplete: Bool { [command, registry, example].contains { !($0 ?? "").isEmpty } }

    package var params: [String: any Sendable] {
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
        if let example, !example.isEmpty {
            params["example"] = example
            if let baseURL, !baseURL.isEmpty { params["baseUrl"] = baseURL }
            if let model, !model.isEmpty { params["model"] = model }
            if let endpointPreset { params["endpointPreset"] = endpointPreset }
            if let servesCloud { params["servesCloud"] = servesCloud }
            if validateEndpoint { params["validateEndpoint"] = true }
            if let apiKey, !apiKey.isEmpty { params["apiKey"] = apiKey }
        }
        if replace { params["replace"] = true }
        if let editEndpoint { params["editEndpoint"] = editEndpoint }
        return params
    }

    /// Splits a typed argument line the way a shell would for plain words and quotes.
    package static func words(_ line: String) -> [String] {
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

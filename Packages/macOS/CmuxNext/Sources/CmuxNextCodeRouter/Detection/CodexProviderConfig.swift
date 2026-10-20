import Foundation

/// How Codex authenticates, from its `config.toml`, picked the way Codex
/// picks it (hq#2569 #2): the active `profile`'s `model_provider`, else the
/// top level's, else `openai`. Only `openai` (and a provider with
/// `requires_openai_auth = true`) uses the ChatGPT or API-key sign-in in
/// `auth.json` or the Keychain. Any other provider carries its own
/// credential (a bearer token in the config, an `env_key`, an auth command)
/// or needs none (a local server, a proxy such as sr), so a missing
/// `auth.json` says nothing about whether Codex works. Mirrors acpmux's
/// `harness_health/codex_provider.rs`.
///
/// Presence only: no value is kept; names (the provider's id or `name`, an
/// environment variable's name) come back for the row's detail.
struct CodexProviderConfig: Equatable {
    enum Auth: Equatable {
        /// The OpenAI sign-in decides (`auth.json` or the Keychain).
        case openAILogin
        /// A provider of its own that has what it needs. `envKey`: the
        /// variable it reads its key from, when it names one.
        case configured(name: String, envKey: String?)
        /// A provider of its own that lacks what it names (an unset
        /// `env_key`, a provider the config does not define).
        case missing(name: String)
    }

    /// Codex's own providers that run on this machine and need no key.
    static let localBuiltins: Set<String> = ["oss", "ollama", "lmstudio"]

    static func auth(configText: String, value: (String) -> String?) -> Auth {
        let toml = MiniTOML(configText)
        let profile = toml.string(["profile"]).flatMap { toml.string(["profiles", $0, "model_provider"]) }
        let id = profile ?? toml.string(["model_provider"]) ?? "openai"
        // Codex's own providers win over a same-named table.
        if id == "openai" { return .openAILogin }
        if localBuiltins.contains(id) { return .configured(name: id, envKey: nil) }
        let table = ["model_providers", id]
        guard toml.hasTable(table) else { return .missing(name: id) }
        if toml.bool(table + ["requires_openai_auth"]) == true { return .openAILogin }
        let name = toml.string(table + ["name"]).flatMap { $0.isEmpty ? nil : $0 } ?? id
        if let token = toml.string(table + ["experimental_bearer_token"]),
           !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .configured(name: name, envKey: nil)
        }
        if toml.has(table + ["auth", "command"]) { return .configured(name: name, envKey: nil) }
        if let key = toml.string(table + ["env_key"]), !key.isEmpty {
            return value(key) == nil ? .missing(name: name) : .configured(name: name, envKey: key)
        }
        return .configured(name: name, envKey: nil)
    }
}

/// The part of TOML Codex's provider settings use: `[table.headers]`,
/// `key = value` with dotted and quoted keys, and string and boolean
/// values. Anything else (arrays, inline tables, multi-line strings) is
/// kept only as present. Never throws: a line it cannot read is skipped.
struct MiniTOML {
    enum Value: Equatable {
        case string(String)
        case bool(Bool)
        case other
    }

    private(set) var values: [[String]: Value] = [:]
    private(set) var tables: Set<[String]> = [[]]

    init(_ text: String) {
        var table: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[[") { table = ["\u{0}array"]; continue }
            if line.hasPrefix("["), let close = Self.closingBracket(line) {
                table = Self.keyPath(String(line[line.index(after: line.startIndex)..<close]))
                for depth in 1...max(table.count, 1) { tables.insert(Array(table.prefix(depth))) }
                continue
            }
            guard let equals = Self.unquotedEquals(line) else { continue }
            let key = Self.keyPath(String(line[..<equals]))
            guard !key.isEmpty else { continue }
            let path = table + key
            for depth in table.count..<path.count { tables.insert(Array(path.prefix(depth))) }
            values[path] = Self.value(String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces))
        }
    }

    func string(_ path: [String]) -> String? {
        if case .string(let text) = values[path] { return text }
        return nil
    }

    func bool(_ path: [String]) -> Bool? {
        if case .bool(let flag) = values[path] { return flag }
        return nil
    }

    func has(_ path: [String]) -> Bool { values[path] != nil }

    func hasTable(_ path: [String]) -> Bool { tables.contains(path) }

    /// `a.b."c.d"` -> `["a", "b", "c.d"]`.
    static func keyPath(_ text: String) -> [String] {
        var parts: [String] = [], current = "", quote: Character?
        for character in text {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "." {
                parts.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts.contains(where: \.isEmpty) ? [] : parts
    }

    private static func closingBracket(_ line: String) -> String.Index? {
        var quote: Character?
        for index in line.indices {
            let character = line[index]
            if let open = quote { if character == open { quote = nil } } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "]" {
                return index
            }
        }
        return nil
    }

    private static func unquotedEquals(_ line: String) -> String.Index? {
        var quote: Character?
        for index in line.indices {
            let character = line[index]
            if let open = quote { if character == open { quote = nil } } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "=" {
                return index
            }
        }
        return nil
    }

    private static func value(_ text: String) -> Value {
        if text.hasPrefix("\"\"\"") || text.hasPrefix("'''") { return .other }
        if let open = text.first, open == "\"" || open == "'" {
            var result = "", escaped = false
            for character in text.dropFirst() {
                if escaped { result.append(character); escaped = false; continue }
                if character == "\\" && open == "\"" { escaped = true; continue }
                if character == open { return .string(result) }
                result.append(character)
            }
            return .other
        }
        let bare = text.split(separator: "#", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if bare == "true" { return .bool(true) }
        if bare == "false" { return .bool(false) }
        return .other
    }
}

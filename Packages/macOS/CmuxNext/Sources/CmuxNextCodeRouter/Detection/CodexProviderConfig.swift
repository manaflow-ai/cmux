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
/// Presence only: the parsed config is read for structure and names (the
/// provider's id or `name`, an environment variable's name), which come
/// back for the row's detail; ``ProviderDetector/detectCodex()`` makes one
/// per detection and drops it.
struct CodexProviderConfig {
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
    let localBuiltins: Set<String> = ["oss", "ollama", "lmstudio"]
    private let toml: MiniTOML

    init(text: String) {
        toml = MiniTOML(text)
    }

    /// The selected provider's sign-in; `value` reads an environment
    /// variable (set or not) for an `env_key`.
    func auth(value: (String) -> String?) -> Auth {
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

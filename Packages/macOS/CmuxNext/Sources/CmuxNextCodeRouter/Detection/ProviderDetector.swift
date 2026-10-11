import Foundation

/// Detects every provider's local sign-in from a ``DetectionEnvironment``.
///
/// Presence only: files are parsed for structure and plain identity fields
/// (an email, a plan, a profile name); Keychain items are checked by
/// attributes, never read; environment variables are checked for being
/// set. No secret value is returned, logged or kept. An email or login is
/// read only inside one detect function, turned into an ``AccountLabel``
/// there and dropped. Runs off the main actor: file and Keychain reads are
/// synchronous IO.
public struct ProviderDetector: Sendable {
    public let environment: DetectionEnvironment

    public init(environment: DetectionEnvironment) {
        self.environment = environment
    }

    /// Every provider in ``AIProvider/allCases`` order. Local servers are
    /// probed concurrently, each under its own deadline.
    public func detectAll() async -> [ProviderDetection] {
        async let ollama = detectOllama()
        async let lmStudio = detectLMStudio()
        let servers = await [AIProvider.ollama: ollama, .lmStudio: lmStudio]
        return AIProvider.allCases.map { servers[$0] ?? detectLocal($0) }
    }

    /// One provider that needs no network.
    public func detectLocal(_ provider: AIProvider) -> ProviderDetection {
        switch provider {
        case .codex: detectCodex()
        case .claude: detectClaudeCode()
        case .gemini: detectGemini()
        case .bedrock: detectBedrock()
        case .vertex: detectVertex()
        case .copilot: detectCopilot()
        case .openAI, .anthropic, .openRouter, .groq, .xai, .mistral, .deepseek: detectAPIKey(provider)
        case .ollama, .lmStudio, .openCodeGo: .missing(provider)
        }
    }

    /// A provider whose only credential is an API key: the environment, or
    /// a key saved in cmux's Keychain item.
    func detectAPIKey(_ provider: AIProvider) -> ProviderDetection {
        var sources = provider.apiKeyEnvironmentKeys.filter { environment.value($0) != nil }.map(DetectionSource.environment)
        if environment.savedKeys.contains(provider) { sources.append(.cmuxKeychain) }
        return ProviderDetection(provider: provider, status: sources.isEmpty ? .missing : .signedIn, sources: sources)
    }

    // MARK: Local servers

    func detectOllama() async -> ProviderDetection {
        let host = environment.value("OLLAMA_HOST").map(Self.ollamaBase) ?? Self.ollamaDefault
        return await probe(.ollama, base: host, path: "api/tags")
    }

    func detectLMStudio() async -> ProviderDetection {
        await probe(.lmStudio, base: Self.lmStudioDefault, path: "v1/models")
    }

    // Literals a test parses; /dev/null stands in rather than a trap.
    static let ollamaDefault = URL(string: "http://127.0.0.1:11434") ?? URL(fileURLWithPath: "/dev/null")
    static let lmStudioDefault = URL(string: "http://127.0.0.1:1234") ?? URL(fileURLWithPath: "/dev/null")

    private func probe(_ provider: AIProvider, base: URL, path: String) async -> ProviderDetection {
        let address = [base.host, base.port.map(String.init)].compactMap { $0 }.joined(separator: ":")
        let reachable = await environment.servers.isReachable(base.appendingPathComponent(path))
        return ProviderDetection(provider: provider, status: reachable ? .signedIn : .missing,
                                 detail: reachable ? address : nil, sources: reachable ? [.server(address)] : [])
    }

    /// The account label of a raw identity, or nil when there is none.
    func account(_ provider: AIProvider, _ identity: String?, plan: String? = nil) -> AccountLabel? {
        guard let identity = identity?.trimmingCharacters(in: .whitespacesAndNewlines), !identity.isEmpty else { return nil }
        return environment.labeler.local(provider, identity: identity, plan: plan)
    }

    /// `OLLAMA_HOST` may be `host`, `host:port` or a URL.
    static func ollamaBase(_ raw: String) -> URL {
        let withScheme = raw.contains("://") ? raw : "http://" + raw
        guard var components = URLComponents(string: withScheme), components.host?.isEmpty == false else {
            return ollamaDefault
        }
        if components.host == "0.0.0.0" { components.host = "127.0.0.1" }
        if components.port == nil { components.port = 11434 }
        components.path = ""
        return components.url ?? ollamaDefault
    }
}

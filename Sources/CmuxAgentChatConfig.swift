import Foundation

struct CmuxAgentChatConfigDefinition: Codable, Sendable, Hashable {
    var url: String?
    var startCommand: String?

    private enum CodingKeys: String, CodingKey {
        case url
        case startCommand
    }

    init(url: String? = nil, startCommand: String? = nil) {
        self.url = url
        self.startCommand = startCommand
    }

    var hasServerFields: Bool {
        url != nil || startCommand != nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decodedURL = try Self.trimmedString(forKey: .url, in: container) {
            guard Self.isValidServerURL(decodedURL) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .url,
                    in: container,
                    debugDescription: "agentChat.url must be an absolute http or https URL"
                )
            }
            url = decodedURL
        } else {
            url = nil
        }
        startCommand = try Self.trimmedString(forKey: .startCommand, in: container)
    }

    private static func trimmedString(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> String? {
        guard container.contains(key) else { return nil }
        let value = try container.decode(String.self, forKey: key)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "agentChat.\(key.stringValue) must not be blank"
            )
        }
        return value
    }

    private static func isValidServerURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              URL(string: value) != nil else {
            return false
        }
        return true
    }
}

enum CmuxAgentChatConfigurationSource: Sendable, Hashable {
    case local(path: String)
    case global(path: String)
    case defaults

    var sourcePath: String? {
        switch self {
        case .local(let path), .global(let path):
            return path
        case .defaults:
            return nil
        }
    }

    var isLocal: Bool {
        if case .local = self { return true }
        return false
    }
}

struct CmuxAgentChatConfiguration: Sendable, Hashable {
    static let defaultURLString = "http://127.0.0.1:7739"
    static let `default` = CmuxAgentChatConfiguration(
        url: URL(string: defaultURLString)!,
        startCommand: nil,
        source: .defaults,
        hasExplicitURL: false
    )

    var url: URL
    var startCommand: String?
    var source: CmuxAgentChatConfigurationSource
    var hasExplicitURL: Bool

    var startCommandRequiresTrust: Bool {
        source.isLocal && startCommand != nil
    }

    var healthURL: URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = "/healthz"
        components?.query = nil
        components?.fragment = nil
        return components?.url ?? url.appendingPathComponent("healthz")
    }

    static func resolved(
        local: CmuxAgentChatConfigDefinition?,
        global: CmuxAgentChatConfigDefinition?
    ) -> CmuxAgentChatConfiguration {
        resolved(
            local: local,
            global: global,
            localSourcePath: nil,
            globalSourcePath: nil
        )
    }

    static func resolved(
        local: CmuxAgentChatConfigDefinition?,
        global: CmuxAgentChatConfigDefinition?,
        localSourcePath: String?,
        globalSourcePath: String?
    ) -> CmuxAgentChatConfiguration {
        let definition: CmuxAgentChatConfigDefinition?
        let source: CmuxAgentChatConfigurationSource
        if let local, local.hasServerFields {
            definition = local
            source = localSourcePath.map { .local(path: $0) } ?? .defaults
        } else if let global {
            definition = global
            source = globalSourcePath.map { .global(path: $0) } ?? .defaults
        } else {
            definition = nil
            source = .defaults
        }
        let rawURL = definition?.url ?? Self.defaultURLString
        return CmuxAgentChatConfiguration(
            url: URL(string: rawURL) ?? Self.default.url,
            startCommand: definition?.startCommand,
            source: source,
            hasExplicitURL: definition?.url != nil
        )
    }
}

struct AgentChatOwnedServerSession: Sendable, Hashable {
    var port: Int
    var pid: Int
    var token: String

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    var healthURL: URL {
        baseURL.appendingPathComponent("healthz")
    }

    var browserURL: URL {
        Self.browserURL(port: port, token: token)
    }

    var themeURL: URL {
        baseURL
            .appendingPathComponent(token, isDirectory: true)
            .appendingPathComponent("api", isDirectory: true)
            .appendingPathComponent("theme")
    }

    static func browserURL(port: Int, token: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)/\(token)/")!
    }
}

struct AgentChatSidecarStateFile: Decodable, Sendable, Hashable {
    var port: Int
    var pid: Int

    func session(token: String) -> AgentChatOwnedServerSession? {
        guard (1...65_535).contains(port), pid > 0 else { return nil }
        return AgentChatOwnedServerSession(port: port, pid: pid, token: token)
    }

    static func parse(_ data: Data, token: String) throws -> AgentChatOwnedServerSession? {
        try JSONDecoder().decode(Self.self, from: data).session(token: token)
    }
}

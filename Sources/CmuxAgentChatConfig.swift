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
        source: .defaults
    )

    var url: URL
    var startCommand: String?
    var source: CmuxAgentChatConfigurationSource

    var startCommandRequiresTrust: Bool {
        source.isLocal && startCommand != nil
    }

    var healthURL: URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = basePath.isEmpty ? "/healthz" : "/\(basePath)/healthz"
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
        if let local {
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
            source: source
        )
    }
}

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

enum AgentChatServerMode: Sendable, Hashable {
    case explicitURL
    case appOwned
    case legacyDefaultURL
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

    var serverMode: AgentChatServerMode {
        if hasExplicitURL {
            return .explicitURL
        }
        if startCommand != nil {
            return .appOwned
        }
        return .legacyDefaultURL
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

enum AgentChatSidecarStateFileStore {
    static func stateFileURL() -> URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app"
        return appSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("agent-chat", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    static func prepareStateFileURL() async -> URL? {
        await Task.detached(priority: .utility) {
            guard let stateFileURL = Self.stateFileURL() else { return nil }
            let directoryURL = stateFileURL.deletingLastPathComponent()
            let fileManager = FileManager.default
            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                try Self.sweepStaleStateFiles(in: directoryURL, keeping: stateFileURL)
                try? fileManager.removeItem(at: stateFileURL)
                _ = fileManager.createFile(atPath: stateFileURL.path, contents: nil)
                return stateFileURL
            } catch {
                return nil
            }
        }.value
    }

    static func removeStateFile() async {
        await Task.detached(priority: .utility) {
            guard let stateFileURL = Self.stateFileURL() else { return }
            try? FileManager.default.removeItem(at: stateFileURL)
        }.value
    }

    static func waitForSession(
        stateFileURL: URL,
        token: String
    ) async -> AgentChatOwnedServerSession? {
        await Task.detached(priority: .utility) {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(10))
            while !Task.isCancelled, clock.now < deadline {
                if let data = try? Data(contentsOf: stateFileURL),
                   let session = try? AgentChatSidecarStateFile.parse(data, token: token) {
                    return session
                }
                do {
                    // Bounded, cancellable polling for the sidecar readiness state file.
                    try await clock.sleep(for: .milliseconds(250))
                } catch {
                    return nil
                }
            }
            return nil
        }.value
    }

    private static func sweepStaleStateFiles(
        in directoryURL: URL,
        keeping currentStateFileURL: URL
    ) throws {
        let fileManager = FileManager.default
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let stateFiles = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        for fileURL in stateFiles where fileURL != currentStateFileURL {
            guard fileURL.pathExtension == "json" else { continue }
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
            if (values?.contentModificationDate ?? .distantPast) < cutoff {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }
}

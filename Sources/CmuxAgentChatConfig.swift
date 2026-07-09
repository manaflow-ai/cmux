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

nonisolated struct AgentChatSidecarStateFile: Decodable, Sendable, Hashable {
    var port: Int
    var pid: Int
    var launchId: String?

    func session(token: String, launchId expectedLaunchId: String) -> AgentChatOwnedServerSession? {
        guard launchId == expectedLaunchId else { return nil }
        guard (1...65_535).contains(port), pid > 0 else { return nil }
        return AgentChatOwnedServerSession(port: port, pid: pid, token: token)
    }

    static func parse(
        _ data: Data,
        token: String,
        launchId: String
    ) throws -> AgentChatOwnedServerSession? {
        try JSONDecoder().decode(Self.self, from: data).session(token: token, launchId: launchId)
    }
}

// FileManager is thread-safe for independent file operations; the wrapper is
// captured by detached utility tasks so the store can keep injected I/O.
final class AgentChatSidecarFileSystem: @unchecked Sendable {
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }
}

struct AgentChatSidecarStateFileStore: Sendable {
    var directoryURL: URL
    var fileSystem: AgentChatSidecarFileSystem

    static func live() -> AgentChatSidecarStateFileStore? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app"
        return AgentChatSidecarStateFileStore(
            directoryURL: appSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("agent-chat", isDirectory: true),
            fileSystem: AgentChatSidecarFileSystem()
        )
    }

    func stateFileURL(launchId: String) -> URL {
        directoryURL.appendingPathComponent("state-\(launchId).json")
    }

    func prepareStateFileURL(launchId: String, launchDate: Date) async -> URL? {
        let stateFileURL = stateFileURL(launchId: launchId)
        let fileSystem = fileSystem
        return await Task.detached(priority: .utility) { () -> URL? in
            let directoryURL = stateFileURL.deletingLastPathComponent()
            let fileManager = fileSystem.fileManager
            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                try Self.sweepStaleStateFiles(
                    in: directoryURL,
                    keeping: stateFileURL,
                    olderThan: launchDate,
                    fileManager: fileManager
                )
                try? fileManager.removeItem(at: stateFileURL)
                guard fileManager.createFile(atPath: stateFileURL.path, contents: nil) else {
                    return nil
                }
                return stateFileURL
            } catch {
                return nil
            }
        }.value
    }

    func removeStateFile(launchId: String? = nil) async {
        let stateFileURL = launchId.map { self.stateFileURL(launchId: $0) }
        let directoryURL = directoryURL
        let fileSystem = fileSystem
        await Task.detached(priority: .utility) {
            if let stateFileURL {
                try? fileSystem.fileManager.removeItem(at: stateFileURL)
            } else if let files = try? fileSystem.fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            ) {
                for fileURL in files where Self.isStateFile(fileURL) {
                    try? fileSystem.fileManager.removeItem(at: fileURL)
                }
            }
        }.value
    }

    func waitForSession(
        token: String,
        launchId: String,
        launchDate: Date
    ) async -> AgentChatOwnedServerSession? {
        let stateFileURL = stateFileURL(launchId: launchId)
        let fileSystem = fileSystem
        return await Task.detached(priority: .utility) { () -> AgentChatOwnedServerSession? in
            let fileManager = fileSystem.fileManager
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(10))
            while !Task.isCancelled, clock.now < deadline {
                if let data = try? Data(contentsOf: stateFileURL),
                   let stateFile = try? JSONDecoder().decode(AgentChatSidecarStateFile.self, from: data) {
                    if let session = stateFile.session(token: token, launchId: launchId) {
                        try? fileManager.removeItem(at: stateFileURL)
                        return session
                    }
                    let values = try? stateFileURL.resourceValues(forKeys: [.contentModificationDateKey])
                    if (values?.contentModificationDate ?? .distantPast) < launchDate {
                        try? fileManager.removeItem(at: stateFileURL)
                    }
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
        keeping currentStateFileURL: URL,
        olderThan cutoff: Date,
        fileManager: FileManager
    ) throws {
        let stateFiles = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        for fileURL in stateFiles where fileURL != currentStateFileURL {
            guard isStateFile(fileURL) else { continue }
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
            if (values?.contentModificationDate ?? .distantPast) < cutoff {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }

    private static func isStateFile(_ fileURL: URL) -> Bool {
        let name = fileURL.lastPathComponent
        return name.hasPrefix("state-") && name.hasSuffix(".json")
    }
}

import Foundation

/// Reads durable agent hook bindings without process inspection.
///
/// The session index owns titles and resume commands. This store only supplies
/// the latest workspace and terminal identity recorded for each session so
/// History can place that session in the topology tree.
actor VaultHistoryAgentBindingStore {
    struct Key: Hashable, Sendable {
        let agentId: String
        let sessionId: String
    }

    struct Binding: Equatable, Sendable {
        let key: Key
        let workspaceId: UUID
        let surfaceId: UUID
        let updatedAt: Date
    }

    private static let maximumBindings = 5_000

    private let homeDirectory: String
    private let fileManager: FileManager
    private let environment: [String: String]
    private var cachedFingerprint: [String: Date?] = [:]
    private var cachedBindings: [Key: Binding] = [:]

    init(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.environment = environment
    }

    func load() -> [Key: Binding] {
        let registry = CmuxVaultAgentRegistry.load(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        let builtInIds = Set(RestorableAgentKind.allCases.map(\.rawValue))
        let agentIds = RestorableAgentKind.allCases.map(\.rawValue)
            + registry.registrations.map(\.id).filter { !builtInIds.contains($0) }
        let storeURLs = agentIds.compactMap { RestorableAgentKind(rawValue: $0) }.map {
            (
                agentId: $0.rawValue,
                url: $0.hookStoreFileURL(
                    homeDirectory: homeDirectory,
                    environment: environment
                )
            )
        }
        let fingerprint = Dictionary(uniqueKeysWithValues: storeURLs.map { item in
            (
                item.url.path,
                try? item.url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
            )
        })
        if fingerprint == cachedFingerprint {
            return cachedBindings
        }

        let decoder = JSONDecoder()
        var bindings: [Key: Binding] = [:]
        for item in storeURLs {
            guard fileManager.fileExists(atPath: item.url.path),
                  let data = try? Data(contentsOf: item.url),
                  let state = try? decoder.decode(
                      RestorableAgentHookSessionStoreFile.self,
                      from: data
                  ) else {
                continue
            }
            for record in state.sessions.values {
                let sessionId = record.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sessionId.isEmpty,
                      let workspaceId = UUID(uuidString: record.workspaceId),
                      let surfaceId = UUID(uuidString: record.surfaceId) else {
                    continue
                }
                let key = Key(agentId: item.agentId, sessionId: sessionId)
                let binding = Binding(
                    key: key,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    updatedAt: Date(timeIntervalSince1970: record.updatedAt)
                )
                if bindings[key]?.updatedAt ?? .distantPast <= binding.updatedAt {
                    bindings[key] = binding
                }
            }
        }
        if bindings.count > Self.maximumBindings {
            let newest = bindings.values
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(Self.maximumBindings)
            bindings = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0) })
        }
        cachedFingerprint = fingerprint
        cachedBindings = bindings
        return bindings
    }
}

import Foundation

/// Serializes read-modify-write automation mutations for one configuration
/// file so concurrent socket requests cannot overwrite each other.
actor AutomationConfigMutationCoordinator {
    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func load() throws -> AutomationConfiguration {
        try AutomationConfigStore(
            fileURL: fileURL,
            fileManager: fileManager,
            mutationCoordinator: self
        ).load()
    }

    func updateRule(
        id: String,
        _ update: @Sendable (inout AutomationRule) -> Void
    ) throws -> AutomationRule {
        let store = AutomationConfigStore(
            fileURL: fileURL,
            fileManager: fileManager,
            mutationCoordinator: self
        )
        var configuration = try store.load()
        guard let index = configuration.rules.firstIndex(where: { $0.id == id }) else {
            throw AutomationConfigStoreError.ruleNotFound(id)
        }
        update(&configuration.rules[index])
        try store.save(configuration)
        return configuration.rules[index]
    }
}

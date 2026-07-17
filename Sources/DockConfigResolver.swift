import Foundation

struct DockConfigResolver: Sendable {
    private struct LocatedConfig: Sendable {
        let location: DockConfigLocation
        let fileSystem: any DockConfigFileSystem
        let baseDirectory: String
        let isProjectSource: Bool
        let executionContext: DockExecutionContext
    }

    private let globalFileSystem: any DockConfigFileSystem
    private let globalConfigPath: DockConfigPath
    private let globalBaseDirectory: DockConfigPath

    init(
        globalFileSystem: any DockConfigFileSystem = LocalDockConfigFileSystem(),
        globalConfigPath: DockConfigPath? = nil,
        globalBaseDirectory: DockConfigPath? = nil
    ) {
        let home = DockConfigPath(FileManager.default.homeDirectoryForCurrentUser.path)!
        self.globalFileSystem = globalFileSystem
        self.globalConfigPath = globalConfigPath ?? DockConfigPath(DockSplitStore.globalConfigURL().path)!
        self.globalBaseDirectory = globalBaseDirectory ?? home
    }

    func resolve(context: DockConfigurationContext) async throws -> DockConfigResolution {
        guard let located = try await locate(context: context) else {
            return DockConfigResolution(
                controls: [],
                sourceLocation: nil,
                baseDirectory: context.emptyBaseDirectory,
                isProjectSource: false,
                executionContext: .local
            )
        }
        let data = try await located.fileSystem.readFile(at: located.location.path)
        let file = try JSONDecoder().decode(DockConfigFile.self, from: data)
        var seen = Set<String>()
        for control in file.controls where !seen.insert(control.id).inserted {
            throw NSError(domain: "cmux.dock", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(
                    localized: "dock.error.duplicateControl",
                    defaultValue: "Dock control ids must be unique."
                ),
            ])
        }
        return DockConfigResolution(
            controls: file.controls,
            sourceLocation: located.location,
            baseDirectory: located.baseDirectory,
            isProjectSource: located.isProjectSource,
            executionContext: located.executionContext
        )
    }

    func identity(context: DockConfigurationContext) async throws -> DockConfigIdentity {
        guard let located = try await locate(context: context) else {
            return DockConfigIdentity(sourceLocation: nil, baseDirectory: context.emptyBaseDirectory)
        }
        return DockConfigIdentity(
            sourceLocation: located.location,
            baseDirectory: located.baseDirectory
        )
    }

    private func locate(context: DockConfigurationContext) async throws -> LocatedConfig? {
        if let project = context.projectSource,
           let located = try await locateProjectConfig(project) {
            return located
        }
        guard context.includesGlobalFallback else { return nil }
        let metadata = try await globalFileSystem.metadata(at: globalConfigPath.value)
        guard metadata.exists, metadata.kind == .file else { return nil }
        return LocatedConfig(
            location: DockConfigLocation(origin: .local, path: globalConfigPath.value),
            fileSystem: globalFileSystem,
            baseDirectory: globalBaseDirectory.value,
            isProjectSource: false,
            executionContext: .local
        )
    }

    private func locateProjectConfig(
        _ source: DockProjectConfigSource
    ) async throws -> LocatedConfig? {
        var directory = source.rootDirectory
        let rootMetadata = try await source.fileSystem.metadata(at: directory.value)
        guard rootMetadata.exists else { return nil }
        if rootMetadata.kind != .directory {
            guard let parent = directory.parent else { return nil }
            directory = parent
        }

        while true {
            try Task.checkCancellation()
            let configPath = directory.appending(".cmux/dock.json")
            let metadata = try await source.fileSystem.metadata(at: configPath.value)
            if metadata.exists, metadata.kind == .file {
                return LocatedConfig(
                    location: DockConfigLocation(origin: source.origin, path: configPath.value),
                    fileSystem: source.fileSystem,
                    baseDirectory: directory.value,
                    isProjectSource: true,
                    executionContext: source.executionContext
                )
            }
            if directory == source.boundaryDirectory { return nil }
            guard let parent = directory.parent else { return nil }
            directory = parent
        }
    }
}

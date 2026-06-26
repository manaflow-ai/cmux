public import Foundation

/// Resolves the active Dock configuration from disk.
///
/// Walks upward from a project root for a `.cmux/dock.json`, falls back to the
/// global `~/.config/cmux/dock.json`, decodes the file into a
/// ``DockConfigResolution``, exposes the editable config location, and writes a
/// starter template on first open.
///
/// `CmuxSidebar` has no localization bundle, so the app injects the already
/// localized error and source-label strings (the same reason
/// ``DockControlDecodingStrings`` exists): calling `String(localized:)` here
/// would bind to the package bundle, drop every non-English translation, and
/// silently return the English default. The resolver therefore never localizes;
/// it holds the resolved strings the app passes in at construction.
public struct DockConfigResolver {
    /// App-localized decode error messages forwarded into the JSON decoder.
    public let decodingStrings: DockControlDecodingStrings
    /// Message for the error thrown when two controls share an `id`.
    public let duplicateControlMessage: String
    /// Source label shown when no Dock config file exists.
    public let sourceTitle: String
    /// Source label shown for a project-scoped Dock config.
    public let sourceProject: String
    /// Source label shown for the global Dock config.
    public let sourceGlobal: String

    /// Creates a resolver with the app-localized strings it returns and throws.
    public init(
        decodingStrings: DockControlDecodingStrings,
        duplicateControlMessage: String,
        sourceTitle: String,
        sourceProject: String,
        sourceGlobal: String
    ) {
        self.decodingStrings = decodingStrings
        self.duplicateControlMessage = duplicateControlMessage
        self.sourceTitle = sourceTitle
        self.sourceProject = sourceProject
        self.sourceGlobal = sourceGlobal
    }

    /// Resolves the active Dock configuration: project config wins over global,
    /// and an absent config yields an empty resolution rooted at `rootDirectory`.
    public func resolve(rootDirectory: String?) throws -> DockConfigResolution {
        if let projectURL = projectConfigURL(rootDirectory: rootDirectory) {
            return try loadConfig(
                from: projectURL,
                baseDirectory: projectBaseDirectory(for: projectURL),
                isProjectSource: true
            )
        }

        let globalURL = globalConfigURL()
        if FileManager.default.fileExists(atPath: globalURL.path) {
            return try loadConfig(
                from: globalURL,
                baseDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
                isProjectSource: false
            )
        }

        return DockConfigResolution(
            controls: [],
            sourceURL: nil,
            baseDirectory: rootDirectory.flatMap(existingDirectory) ?? FileManager.default.homeDirectoryForCurrentUser.path,
            isProjectSource: false
        )
    }

    /// Returns the label describing where the resolution's controls came from.
    public func sourceLabel(for resolution: DockConfigResolution) -> String {
        if resolution.sourceURL == nil {
            return sourceTitle
        }
        return resolution.isProjectSource ? sourceProject : sourceGlobal
    }

    /// The path the user should edit: the project `.cmux/dock.json` when a
    /// project root exists, otherwise the global config.
    public func preferredEditableConfigURL(rootDirectory: String?) throws -> URL {
        if let rootDirectory = rootDirectory.flatMap(existingDirectory) {
            return URL(fileURLWithPath: rootDirectory, isDirectory: true)
                .appendingPathComponent(".cmux", isDirectory: true)
                .appendingPathComponent("dock.json", isDirectory: false)
        }
        return globalConfigURL()
    }

    /// Writes a starter Dock config (a single `lazygit` control) to `url`.
    public func writeTemplate(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let file = DockConfigFile(controls: [
            DockControlDefinition(
                id: "git",
                title: "Git",
                command: "lazygit",
                height: 300
            )
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(file)
        try data.write(to: url, options: .atomic)
    }

    private func loadConfig(
        from url: URL,
        baseDirectory: String,
        isProjectSource: Bool
    ) throws -> DockConfigResolution {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.userInfo[.dockControlDecodingStrings] = decodingStrings
        let file = try decoder.decode(DockConfigFile.self, from: data)
        var seen = Set<String>()
        for control in file.controls {
            guard seen.insert(control.id).inserted else {
                throw NSError(
                    domain: "cmux.dock",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: duplicateControlMessage
                    ]
                )
            }
        }
        return DockConfigResolution(
            controls: file.controls,
            sourceURL: url,
            baseDirectory: baseDirectory,
            isProjectSource: isProjectSource
        )
    }

    private func projectConfigURL(rootDirectory: String?) -> URL? {
        guard let rootDirectory = rootDirectory.flatMap(existingDirectory) else { return nil }
        var candidate = URL(fileURLWithPath: rootDirectory, isDirectory: true)
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        while true {
            let configURL = candidate
                .appendingPathComponent(".cmux", isDirectory: true)
                .appendingPathComponent("dock.json", isDirectory: false)
            if FileManager.default.fileExists(atPath: configURL.path) {
                return configURL
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path || candidate.path == homePath {
                return nil
            }
            candidate = parent
        }
    }

    private func projectBaseDirectory(for configURL: URL) -> String {
        let cmuxDirectory = configURL.deletingLastPathComponent()
        return cmuxDirectory.deletingLastPathComponent().path
    }

    private func globalConfigURL() -> URL {
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_MODE"] == "1",
           let testPath = ProcessInfo.processInfo.environment["CMUX_UI_TEST_DOCK_CONFIG_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !testPath.isEmpty {
            return URL(fileURLWithPath: testPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmux/dock.json", isDirectory: false)
    }

    private func existingDirectory(_ rawPath: String) -> String? {
        let expanded = (rawPath as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) else {
            return nil
        }
        return isDirectory.boolValue ? expanded : (expanded as NSString).deletingLastPathComponent
    }
}

import Foundation
import SwiftUI

extension DockSplitStore {
    // MARK: - Config resolution

    /// Resolves the config that seeds a Dock of the given scope.
    ///
    /// - `.workspace`: only the project `.cmux/dock.json` (searched upward from
    ///   `rootDirectory`); no global fallback, so the Workspace Dock stays
    ///   distinct from the Global Dock. Empty when there is no project config.
    /// - `.global`: only `~/.config/cmux/dock.json` with a home base directory.
    ///
    /// `scope` defaults to `.workspace` to preserve existing call sites/tests.
    nonisolated static func resolve(scope: DockScope = .workspace, rootDirectory: String?) throws -> DockConfigResolution {
        switch scope {
        case .workspace:
            if let projectURL = projectConfigURL(rootDirectory: rootDirectory) {
                return try loadConfig(
                    from: projectURL,
                    baseDirectory: projectBaseDirectory(for: projectURL),
                    isProjectSource: true
                )
            }
            return DockConfigResolution(
                controls: [],
                sourceURL: nil,
                baseDirectory: rootDirectory.flatMap(existingDirectory) ?? FileManager.default.homeDirectoryForCurrentUser.path,
                isProjectSource: false
            )
        case .global:
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
                baseDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
                isProjectSource: false
            )
        }
    }

    nonisolated static func configIdentity(scope: DockScope = .workspace, rootDirectory: String?) -> DockConfigIdentity {
        switch scope {
        case .workspace:
            if let projectURL = projectConfigURL(rootDirectory: rootDirectory) {
                return DockConfigIdentity(
                    sourcePath: canonicalConfigPath(projectURL),
                    baseDirectory: projectBaseDirectory(for: projectURL)
                )
            }
            return DockConfigIdentity(
                sourcePath: nil,
                baseDirectory: rootDirectory.flatMap(existingDirectory) ?? FileManager.default.homeDirectoryForCurrentUser.path
            )
        case .global:
            let globalURL = globalConfigURL()
            if FileManager.default.fileExists(atPath: globalURL.path) {
                return DockConfigIdentity(
                    sourcePath: canonicalConfigPath(globalURL),
                    baseDirectory: FileManager.default.homeDirectoryForCurrentUser.path
                )
            }
            return DockConfigIdentity(
                sourcePath: nil,
                baseDirectory: FileManager.default.homeDirectoryForCurrentUser.path
            )
        }
    }

    nonisolated static func configIdentity(for resolution: DockConfigResolution) -> DockConfigIdentity {
        DockConfigIdentity(
            sourcePath: resolution.sourceURL.map(canonicalConfigPath),
            baseDirectory: resolution.baseDirectory
        )
    }

    nonisolated static func sourceLabel(for resolution: DockConfigResolution) -> String {
        if resolution.sourceURL == nil {
            return String(localized: "dock.source.title", defaultValue: "Dock")
        }
        return resolution.isProjectSource
            ? String(localized: "dock.source.project", defaultValue: "Project Dock")
            : String(localized: "dock.source.global", defaultValue: "Global Dock")
    }

    nonisolated static func preferredEditableConfigURL(scope: DockScope = .workspace, rootDirectory: String?) throws -> URL {
        switch scope {
        case .workspace:
            if let rootDirectory = rootDirectory.flatMap(existingDirectory) {
                return URL(fileURLWithPath: rootDirectory, isDirectory: true)
                    .appendingPathComponent(".cmux", isDirectory: true)
                    .appendingPathComponent("dock.json", isDirectory: false)
            }
            return globalConfigURL()
        case .global:
            return globalConfigURL()
        }
    }

    nonisolated static func writeTemplate(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Intentionally empty: cmux ships no opinionated default controls (no
        // assumed tools like lazygit). The starter file is schema-valid and
        // ready for the user to add their own controls; an empty Dock is a
        // fully supported state — the toolbar `+` menu and empty panes offer
        // New Terminal / New Browser. See docs/dock.md.
        let file = DockConfigFile(controls: [])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(file)
        try data.write(to: url, options: .atomic)
    }

    nonisolated static func prepareEditableConfig(at url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try writeTemplate(to: url)
        }
    }

    nonisolated static func configurationLoadErrorMessage(for error: Error) -> String {
        if let message = dockValidationErrorMessage(for: error) {
            return message
        }
        return String(
            localized: "dock.error.loadFailed",
            defaultValue: "Could not load the Dock config. Check dock.json and try again."
        )
    }

    nonisolated static func configurationOpenErrorMessage(for error: Error) -> String {
        if let message = dockValidationErrorMessage(for: error) {
            return message
        }
        return String(
            localized: "dock.error.openFailed",
            defaultValue: "Could not open the Dock config. Check permissions and try again."
        )
    }

    nonisolated private static func dockValidationErrorMessage(for error: Error) -> String? {
        let nsError = error as NSError
        if nsError.domain == "cmux.dock",
           let message = nsError.userInfo[NSLocalizedDescriptionKey] as? String,
           !message.isEmpty {
            return message
        }

        return nil
    }

    nonisolated static func trustDescriptor(for resolution: DockConfigResolution) -> CmuxActionTrustDescriptor {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(DockConfigFile(controls: resolution.controls))) ?? Data()
        let commandFingerprint = String(data: data, encoding: .utf8) ?? ""
        return CmuxActionTrustDescriptor(
            actionID: "cmux.dock",
            kind: "dockControls",
            command: commandFingerprint,
            target: "rightSidebarDock",
            workspaceCommand: nil,
            configPath: resolution.sourceURL.map { canonicalPath($0.path) },
            projectRoot: canonicalPath(resolution.baseDirectory),
            iconFingerprint: nil
        )
    }

    nonisolated private static func loadConfig(
        from url: URL,
        baseDirectory: String,
        isProjectSource: Bool
    ) throws -> DockConfigResolution {
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(DockConfigFile.self, from: data)
        var seen = Set<String>()
        for control in file.controls {
            guard seen.insert(control.id).inserted else {
                throw NSError(
                    domain: "cmux.dock",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: String(
                            localized: "dock.error.duplicateControl",
                            defaultValue: "Dock control ids must be unique."
                        )
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

    nonisolated private static func projectConfigURL(rootDirectory: String?) -> URL? {
        guard let rootDirectory = rootDirectory.flatMap(existingDirectory) else { return nil }
        var candidatePath = (rootDirectory as NSString).standardizingPath
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        while true {
            let configURL = URL(fileURLWithPath: candidatePath, isDirectory: true)
                .appendingPathComponent(".cmux", isDirectory: true)
                .appendingPathComponent("dock.json", isDirectory: false)
            if FileManager.default.fileExists(atPath: configURL.path) {
                return configURL
            }
            if candidatePath == homePath {
                return nil
            }
            guard let parentPath = parentDirectoryPath(for: candidatePath) else {
                return nil
            }
            candidatePath = parentPath
        }
    }

    nonisolated private static func projectBaseDirectory(for configURL: URL) -> String {
        let cmuxDirectory = configURL.deletingLastPathComponent()
        return cmuxDirectory.deletingLastPathComponent().path
    }

    nonisolated private static func globalConfigURL() -> URL {
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_MODE"] == "1",
           let testPath = ProcessInfo.processInfo.environment["CMUX_UI_TEST_DOCK_CONFIG_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !testPath.isEmpty {
            return URL(fileURLWithPath: testPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmux/dock.json", isDirectory: false)
    }

    nonisolated private static func existingDirectory(_ rawPath: String) -> String? {
        let expanded = (rawPath as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) else {
            return nil
        }
        return isDirectory.boolValue ? expanded : (expanded as NSString).deletingLastPathComponent
    }

    nonisolated private static func canonicalConfigPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    nonisolated private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
            .path
    }

    nonisolated static func parentDirectoryPath(for path: String) -> String? {
        let normalized = (path as NSString).standardizingPath
        guard normalized != "/" else { return nil }
        let parent = (normalized as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != normalized else { return nil }
        return parent
    }
}

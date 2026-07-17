import Foundation
import SwiftUI

extension DockSplitStore {
    // MARK: - Config resolution

    /// Resolves local legacy scope through the same source-aware resolver used
    /// by the visible window Dock.
    nonisolated static func resolve(
        scope: DockScope = .workspace,
        rootDirectory: String?
    ) async throws -> DockConfigResolution {
        try await DockConfigResolver().resolve(
            context: DockConfigurationContext.legacy(scope: scope, rootDirectory: rootDirectory)
        )
    }

    nonisolated static func configIdentity(
        scope: DockScope = .workspace,
        rootDirectory: String?
    ) async throws -> DockConfigIdentity {
        try await DockConfigResolver().identity(
            context: DockConfigurationContext.legacy(scope: scope, rootDirectory: rootDirectory)
        )
    }

    nonisolated static func configIdentity(for resolution: DockConfigResolution) -> DockConfigIdentity {
        DockConfigIdentity(
            sourceLocation: resolution.sourceLocation,
            baseDirectory: resolution.baseDirectory,
            executionWorkspaceID: resolution.executionContext.remoteWorkspaceID
        )
    }

    nonisolated static func sourceLabel(for resolution: DockConfigResolution) -> String {
        if resolution.sourceLocation == nil {
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
            configPath: resolution.sourceLocation?.canonicalIdentifier,
            projectRoot: resolution.sourceLocation.map { location in
                switch location.origin {
                case .local: resolution.baseDirectory
                case .remote: "\(location.origin.identity):\(resolution.baseDirectory)"
                }
            },
            iconFingerprint: nil
        )
    }

    nonisolated static func globalConfigURL() -> URL {
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

    nonisolated static func parentDirectoryPath(for path: String) -> String? {
        DockConfigPath(path)?.parent?.value
    }
}

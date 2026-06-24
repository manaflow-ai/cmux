import CMUXAgentLaunch
import Foundation
import OSLog

// The Vault value-type family (CmuxVaultConfigDefinition, CmuxVaultAgentRegistration,
// CmuxVaultAgentDetectRule, CmuxVaultAgentSessionIDSource, CmuxVaultAgentCWDPolicy,
// CmuxVaultAgentRegistry) now lives in CMUXAgentLaunch (Sources/CMUXAgentLaunch/Vault/).
// The `CmuxVaultAgentDetectRule.matches(_:)` extension moved alongside the rule.
//
// Config-file discovery and decoding stays app-side here because it depends on the
// app god config `CmuxConfigFile` and the app `JSONCParser`, neither of which
// belongs in the package.
extension CmuxVaultAgentRegistry {
    private static let logger = Logger(subsystem: "ai.manaflow.cmux", category: "VaultAgentRegistry")

    func mergingProjectConfig(
        workingDirectory: String?,
        fileManager: FileManager = .default
    ) -> CmuxVaultAgentRegistry {
        guard let workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workingDirectory.isEmpty,
              let path = Self.findLocalConfig(startingAt: workingDirectory, fileManager: fileManager),
              let config = Self.decodeConfig(at: path, fileManager: fileManager),
              let agents = config.vault?.agents,
              !agents.isEmpty else {
            return self
        }
        return CmuxVaultAgentRegistry(registrations: registrations + agents)
    }

    static func load(
        homeDirectory: String = NSHomeDirectory(),
        workingDirectory: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> CmuxVaultAgentRegistry {
        var registrations = [
            CmuxVaultAgentRegistration.builtInPi,
            CmuxVaultAgentRegistration.builtInOmp,
            CmuxVaultAgentRegistration.builtInAntigravity,
            CmuxVaultAgentRegistration.builtInGrok,
        ]
        for path in configPaths(homeDirectory: homeDirectory, workingDirectory: workingDirectory, environment: environment, fileManager: fileManager) {
            guard let config = decodeConfig(at: path, fileManager: fileManager) else { continue }
            registrations.append(contentsOf: config.vault?.agents ?? [])
        }
        return CmuxVaultAgentRegistry(registrations: registrations)
    }

    private static func configPaths(
        homeDirectory: String,
        workingDirectory: String?,
        environment: [String: String],
        fileManager: FileManager
    ) -> [String] {
        let home = (homeDirectory as NSString).standardizingPath
        var paths = [(home as NSString).appendingPathComponent(".config/cmux/cmux.json")]
        let startingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? environment["PWD"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let startingDirectory, !startingDirectory.isEmpty,
           let local = findLocalConfig(startingAt: startingDirectory, fileManager: fileManager) {
            paths.append(local)
        }
        var seen = Set<String>()
        return paths.filter { seen.insert(($0 as NSString).standardizingPath).inserted }
    }

    private static func findLocalConfig(startingAt path: String, fileManager: FileManager) -> String? {
        var isDirectory: ObjCBool = false
        let start = fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            ? path
            : (path as NSString).deletingLastPathComponent
        var current = (start as NSString).standardizingPath
        while true {
            let candidates = [
                ((current as NSString).appendingPathComponent(".cmux") as NSString).appendingPathComponent("cmux.json"),
                (current as NSString).appendingPathComponent("cmux.json"),
            ]
            for candidate in candidates where fileManager.fileExists(atPath: candidate) {
                return candidate
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { return nil }
            current = parent
        }
    }

    private static func decodeConfig(at path: String, fileManager: FileManager) -> CmuxConfigFile? {
        guard fileManager.fileExists(atPath: path),
              let data = fileManager.contents(atPath: path),
              !data.isEmpty else {
            return nil
        }
        do {
            let sanitized = try JSONCParser.preprocess(data: data)
            return try JSONDecoder().decode(CmuxConfigFile.self, from: sanitized)
        } catch {
            logger.fault(
                "Failed to decode config at \(path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}

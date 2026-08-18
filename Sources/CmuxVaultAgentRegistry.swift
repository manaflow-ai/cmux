import CmuxAgentManifests
import CmuxCore
import Foundation
import OSLog

/// App-facing registry assembled from manifest, built-in, and project-config
/// sources. Manifest values remain attached so diagnostics and future
/// reconciliation consumers evaluate the same immutable rules as scanning.
struct CmuxVaultAgentRegistry: Sendable {
    private static let logger = Logger(subsystem: "ai.manaflow.cmux", category: "VaultAgentRegistry")

    var registrations: [CmuxVaultAgentRegistration]
    /// The immutable manifest snapshot that supplied data-driven detectors.
    var manifestEntries: [CmuxAgentManifestEntry]
    /// Compiled once for this registry and reused across every process in a scan.
    var manifestEngine: CmuxAgentDetectionEngine?
    /// Registration ids generated from the accepted manifest snapshot.
    var manifestBackedIDs: Set<String>
    /// Registration ids supplied by global or project `cmux.json` configuration.
    var projectConfiguredIDs: Set<String>
    /// Manifest-backed registrations with complete session contracts.
    var manifestRestorableIDs: Set<String>
    /// The last rejected manifest load error retained for diagnostics.
    var manifestLoadError: CmuxAgentManifestLoadError?

    init(
        registrations: [CmuxVaultAgentRegistration],
        manifestEntries: [CmuxAgentManifestEntry] = [],
        manifestEngine: CmuxAgentDetectionEngine? = nil,
        manifestBackedIDs: Set<String>? = nil,
        projectConfiguredIDs: Set<String> = [],
        manifestRestorableIDs: Set<String>? = nil,
        manifestLoadError: CmuxAgentManifestLoadError? = nil
    ) {
        var ordered: [CmuxVaultAgentRegistration] = []
        var indexesByID: [String: Int] = [:]
        for registration in registrations {
            if let existingIndex = indexesByID[registration.id] {
                ordered[existingIndex] = registration
            } else {
                indexesByID[registration.id] = ordered.count
                ordered.append(registration)
            }
        }
        self.registrations = ordered
        self.manifestEntries = manifestEntries
        self.manifestEngine = if manifestEntries.isEmpty {
            nil
        } else if let manifestEngine {
            manifestEngine
        } else {
            CmuxAgentDetectionEngine(entries: manifestEntries)
        }
        self.manifestBackedIDs = Set(manifestBackedIDs ?? Set(manifestEntries.map { $0.manifest.id }))
            .intersection(Set(ordered.map(\.id)))
        self.projectConfiguredIDs = projectConfiguredIDs.intersection(Set(ordered.map(\.id)))
        self.manifestRestorableIDs = Set(manifestRestorableIDs ?? Set(manifestEntries.compactMap {
            $0.manifest.session?.supportsRestoration == true ? $0.manifest.id : nil
        }))
            .intersection(self.manifestBackedIDs)
        self.manifestLoadError = manifestLoadError
    }

    func registration(id: String) -> CmuxVaultAgentRegistration? {
        registrations.first { $0.id == id }
    }

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
        let overriddenIDs = Set(agents.map(\.id))
        let activeManifestEntries = manifestEntries.filter {
            !overriddenIDs.contains($0.manifest.id)
        }
        return CmuxVaultAgentRegistry(
            registrations: registrations + agents,
            manifestEntries: activeManifestEntries,
            manifestEngine: activeManifestEntries.count == manifestEntries.count
                ? manifestEngine
                : (activeManifestEntries.isEmpty
                    ? nil
                    : CmuxAgentDetectionEngine(entries: activeManifestEntries)),
            manifestBackedIDs: manifestBackedIDs.subtracting(overriddenIDs),
            projectConfiguredIDs: projectConfiguredIDs.union(overriddenIDs),
            manifestRestorableIDs: manifestRestorableIDs.subtracting(overriddenIDs),
            manifestLoadError: manifestLoadError
        )
    }

    static func load(
        homeDirectory: String = NSHomeDirectory(),
        workingDirectory: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        manifestSnapshot: CmuxAgentManifestSnapshot? = nil
    ) -> CmuxVaultAgentRegistry {
        let builtIns = [
            CmuxVaultAgentRegistration.builtInPi,
            CmuxVaultAgentRegistration.builtInOmp,
            CmuxVaultAgentRegistration.builtInCampfire,
            CmuxVaultAgentRegistration.builtInAntigravity,
            CmuxVaultAgentRegistration.builtInGrok,
            CmuxVaultAgentRegistration.builtInKimi,
            CmuxVaultAgentRegistration.builtInHermes,
        ]
        var registrations = builtIns
        var manifestEntries: [CmuxAgentManifestEntry] = []
        var manifestEngine: CmuxAgentDetectionEngine? = nil
        var manifestBackedIDs: Set<String> = []
        var manifestRestorableIDs: Set<String> = []
        var manifestLoadError: CmuxAgentManifestLoadError?
        let userManifestDirectory = CmuxAgentManifestLoader.defaultUserDirectory(
            homeDirectory: URL(fileURLWithPath: (homeDirectory as NSString).standardizingPath)
        )
        do {
            let snapshot: CmuxAgentManifestSnapshot
            if let manifestSnapshot {
                snapshot = manifestSnapshot
            } else {
                let loader = try CmuxAgentManifestLoader.bundled(
                    userDirectory: userManifestDirectory,
                    fileManager: fileManager
                )
                let outcome = try loader.loadWithBundledFallback()
                snapshot = outcome.snapshot
                manifestLoadError = outcome.rejectedOverrideError
            }
            manifestEntries = snapshot.entries
            manifestEngine = snapshot.engine
            manifestBackedIDs = Set(snapshot.entries.map { $0.manifest.id })
            manifestRestorableIDs = Set(snapshot.entries.compactMap {
                $0.manifest.session?.supportsRestoration == true ? $0.manifest.id : nil
            })
            let generatedByID = Dictionary(uniqueKeysWithValues: snapshot.entries.map { entry in
                let fallback = builtIns.first { $0.id == entry.manifest.id }
                let registration = if entry.source == .bundled, let fallback {
                    // Identity matching comes from `manifestEntries`; retaining
                    // the exact compiled value here preserves the specialized
                    // resume/session capabilities that deliberately use value
                    // equality as their trust boundary.
                    fallback
                } else {
                    CmuxVaultAgentRegistration(manifest: entry.manifest, fallback: fallback)
                }
                return (entry.manifest.id, registration)
            })
            // Keep a compiled fallback for a missing built-in resource, while
            // admitting user-defined ids with no Swift registration.
            registrations = builtIns.map { generatedByID[$0.id] ?? $0 }
            registrations.append(contentsOf: snapshot.entries.compactMap { entry in
                builtIns.contains { $0.id == entry.manifest.id } ? nil : generatedByID[entry.manifest.id]
            })
        } catch let error as CmuxAgentManifestLoadError {
            manifestLoadError = error
            logger.error("Bundled agent manifest load failed; using compiled compatibility registrations: \(error.localizedDescription, privacy: .public)")
        } catch {
            let wrapped = CmuxAgentManifestLoadError.invalidFile(path: "", reason: error.localizedDescription)
            manifestLoadError = wrapped
            logger.error("Bundled agent manifest load failed; using compiled compatibility registrations: \(wrapped.localizedDescription, privacy: .public)")
        }
        var configuredIDs: Set<String> = []
        for path in configPaths(
            homeDirectory: homeDirectory,
            workingDirectory: workingDirectory,
            environment: environment,
            fileManager: fileManager
        ) {
            guard let config = decodeConfig(at: path, fileManager: fileManager) else { continue }
            let agents = config.vault?.agents ?? []
            configuredIDs.formUnion(agents.map(\.id))
            registrations.append(contentsOf: agents)
        }
        let activeManifestEntries = manifestEntries.filter {
            !configuredIDs.contains($0.manifest.id)
        }
        return CmuxVaultAgentRegistry(
            registrations: registrations,
            manifestEntries: activeManifestEntries,
            manifestEngine: activeManifestEntries.count == manifestEntries.count
                ? manifestEngine
                : (activeManifestEntries.isEmpty
                    ? nil
                    : CmuxAgentDetectionEngine(entries: activeManifestEntries)),
            manifestBackedIDs: manifestBackedIDs.subtracting(configuredIDs),
            projectConfiguredIDs: configuredIDs,
            manifestRestorableIDs: manifestRestorableIDs.subtracting(configuredIDs),
            manifestLoadError: manifestLoadError
        )
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

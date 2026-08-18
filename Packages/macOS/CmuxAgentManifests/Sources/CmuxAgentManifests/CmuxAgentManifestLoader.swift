public import Foundation
public import CmuxCore

/// Synchronous, deterministic loader. File I/O is injected so package tests
/// never touch a developer's home directory.
/// `FileManager` is an immutable dependency here: every operation is a
/// synchronous, thread-safe Foundation file query and the loader never stores
/// mutable enumeration state. The unchecked conformance keeps the loader
/// injectable into ``CmuxAgentManifestStore`` without exposing Foundation's
/// legacy non-Sendable annotation to callers.
public struct CmuxAgentManifestLoader: @unchecked Sendable {
    /// Raw bundled manifest resources injected by the composition root/tests.
    public let bundledManifestData: [Data]
    /// User override directory, or `nil` to disable overrides.
    public let userDirectory: URL?
    private let fileManager: FileManager

    /// Creates a loader with injectable resources and filesystem dependencies.
    ///
    /// - Parameters:
    ///   - bundledManifestData: Raw JSON resources forming the bundled tier.
    ///   - userDirectory: Optional directory containing user JSON files.
    ///   - fileManager: Filesystem dependency used for override discovery.
    public init(
        bundledManifestData: [Data],
        userDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.bundledManifestData = bundledManifestData
        self.userDirectory = userDirectory
        self.fileManager = fileManager
    }

    /// Creates a loader from JSON resources shipped in this package. The app
    /// uses this composition-root default; tests use the data initializer.
    ///
    /// - Parameters:
    ///   - userDirectory: Optional directory containing user JSON files.
    ///   - fileManager: Filesystem dependency used for override discovery.
    /// - Returns: A loader containing the package's bundled manifest bytes.
    /// - Throws: ``CmuxAgentManifestLoadError`` when a bundled resource cannot
    ///   be read.
    public static func bundled(
        userDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> CmuxAgentManifestLoader {
        let urls = Bundle.module.urls(
            forResourcesWithExtension: "json",
            subdirectory: "agent-detection"
        ) ?? []
        let data = try urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
            do { return try Data(contentsOf: url) }
            catch {
                throw CmuxAgentManifestLoadError.invalidFile(
                    path: url.path,
                    reason: CmuxAgentManifestLocalization.reason(
                        "agentManifest.validation.cannotReadBundled",
                        defaultValue: "Cannot read bundled manifest: \(error.localizedDescription)"
                    )
                )
            }
        }
        return CmuxAgentManifestLoader(
            bundledManifestData: data,
            userDirectory: userDirectory,
            fileManager: fileManager
        )
    }

    /// Returns the conventional per-user override directory.
    ///
    /// - Parameter homeDirectory: Home directory beneath which the path is built.
    /// - Returns: `Library/Application Support/cmux/agent-detection` under the
    ///   supplied home directory.
    public static func defaultUserDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("agent-detection", isDirectory: true)
    }

    /// Loads, validates, overlays, and returns one immutable snapshot.
    ///
    /// - Parameter generation: Generation assigned to the returned snapshot.
    /// - Returns: The accepted catalog in deterministic source order.
    /// - Throws: ``CmuxAgentManifestLoadError`` when either source tier cannot
    ///   be read, merged, or validated.
    public func load(generation: UInt64 = 0) throws -> CmuxAgentManifestSnapshot {
        guard !bundledManifestData.isEmpty else { throw CmuxAgentManifestLoadError.noBundledManifests }
        guard bundledManifestData.count <= CmuxAgentManifestCodec.maximumManifestCount else {
            throw CmuxAgentManifestLoadError.invalidFile(
                path: "bundle",
                reason: CmuxAgentManifestLocalization.reason(
                    "agentManifest.validation.tooManyBundled",
                    defaultValue: "Too many bundled manifests (maximum \(CmuxAgentManifestCodec.maximumManifestCount))"
                )
            )
        }
        var entries: [CmuxAgentManifestEntry] = []
        var indexes: [String: Int] = [:]
        for (index, data) in bundledManifestData.enumerated() {
            let path = "bundle/agent-\(index).json"
            let manifest: CmuxAgentDetectionManifest
            do { manifest = try CmuxAgentManifestCodec.decode(data: data) }
            catch let error as CmuxAgentManifestValidationError {
                throw CmuxAgentManifestLoadError.invalidFile(path: path, reason: error.description)
            } catch {
                throw CmuxAgentManifestLoadError.invalidFile(path: path, reason: error.localizedDescription)
            }
            guard indexes[manifest.id] == nil else {
                throw CmuxAgentManifestLoadError.duplicateID(id: manifest.id, path: path)
            }
            indexes[manifest.id] = entries.count
            entries.append(CmuxAgentManifestEntry(manifest: manifest, source: .bundled, sourcePath: nil))
        }

        guard let userDirectory,
              fileManager.fileExists(atPath: userDirectory.path) else {
            return CmuxAgentManifestSnapshot(entries: entries, generation: generation)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: userDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CmuxAgentManifestLoadError.invalidFile(
                path: userDirectory.path,
                reason: CmuxAgentManifestLocalization.reason(
                    "agentManifest.validation.overrideNotDirectory",
                    defaultValue: "Override path is not a directory"
                )
            )
        }
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: userDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ).filter { url in
                guard url.pathExtension.lowercased() == "json" else { return false }
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else { return false }
                return values.isRegularFile == true
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw CmuxAgentManifestLoadError.invalidFile(
                path: userDirectory.path,
                reason: CmuxAgentManifestLocalization.reason(
                    "agentManifest.validation.cannotEnumerateOverrides",
                    defaultValue: "Cannot enumerate override directory: \(error.localizedDescription)"
                )
            )
        }
        guard urls.count <= CmuxAgentManifestCodec.maximumManifestCount else {
            throw CmuxAgentManifestLoadError.invalidFile(
                path: userDirectory.path,
                reason: CmuxAgentManifestLocalization.reason(
                    "agentManifest.validation.tooManyUserManifests",
                    defaultValue: "Too many user manifests (maximum \(CmuxAgentManifestCodec.maximumManifestCount))"
                )
            )
        }
        for url in urls {
            try applyOverride(
                at: url,
                to: &entries,
                indexes: &indexes
            )
        }
        return CmuxAgentManifestSnapshot(entries: entries, generation: generation)
    }

    /// Loads user overrides and retains validated bundled behavior if an
    /// override is malformed. A broken bundled resource still throws because
    /// there is no trustworthy data-driven catalog to publish.
    ///
    /// - Parameter generation: Generation assigned to either accepted snapshot.
    /// - Returns: A usable snapshot and the rejected override error, if any.
    /// - Throws: ``CmuxAgentManifestLoadError`` when bundled manifests fail.
    public func loadWithBundledFallback(
        generation: UInt64 = 0
    ) throws -> CmuxAgentManifestLoadOutcome {
        do {
            return CmuxAgentManifestLoadOutcome(snapshot: try load(generation: generation))
        } catch let overrideError as CmuxAgentManifestLoadError {
            let bundledSnapshot = try CmuxAgentManifestLoader(
                bundledManifestData: bundledManifestData,
                userDirectory: nil,
                fileManager: fileManager
            ).load(generation: generation)
            return CmuxAgentManifestLoadOutcome(
                snapshot: bundledSnapshot,
                rejectedOverrideError: overrideError
            )
        }
    }

    private func applyOverride(
        at url: URL,
        to entries: inout [CmuxAgentManifestEntry],
        indexes: inout [String: Int]
    ) throws {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch {
            throw CmuxAgentManifestLoadError.invalidFile(
                path: url.path,
                reason: CmuxAgentManifestLocalization.reason(
                    "agentManifest.validation.cannotReadManifest",
                    defaultValue: "Cannot read manifest: \(error.localizedDescription)"
                )
            )
        }
        guard data.count <= CmuxAgentManifestCodec.maximumManifestBytes else {
            throw CmuxAgentManifestLoadError.invalidFile(
                path: url.path,
                reason: CmuxAgentManifestLocalization.reason(
                    "agentManifest.validation.manifestTooLarge",
                    defaultValue: "Manifest exceeds 512 KiB"
                )
            )
        }
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                throw CmuxAgentManifestLoadError.invalidFile(
                    path: url.path,
                    reason: CmuxAgentManifestLocalization.reason(
                        "agentManifest.validation.manifestObject",
                        defaultValue: "Manifest must be a JSON object"
                    )
                )
            }
            object = decoded
        } catch let error as CmuxAgentManifestLoadError { throw error }
        catch {
            throw CmuxAgentManifestLoadError.invalidFile(
                path: url.path,
                reason: CmuxAgentManifestLocalization.reason(
                    "agentManifest.validation.invalidJSON",
                    defaultValue: "Invalid JSON: \(error.localizedDescription)"
                )
            )
        }
        guard let rawID = object["id"] as? String else {
            throw CmuxAgentManifestLoadError.invalidFile(
                path: url.path,
                reason: CmuxAgentManifestLocalization.reason(
                    "agentManifest.validation.idRequired",
                    defaultValue: "id is required"
                )
            )
        }
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        let filenameID = url.deletingPathExtension().lastPathComponent
        guard filenameID == id else {
            throw CmuxAgentManifestLoadError.invalidOverrideFilename(path: url.path, id: id)
        }
        let strategy: String
        if let rawStrategy = object["mergeStrategy"] {
            guard let value = rawStrategy as? String else {
                throw CmuxAgentManifestLoadError.invalidFile(
                    path: url.path,
                    reason: CmuxAgentManifestLocalization.reason(
                        "agentManifest.validation.mergeStrategy",
                        defaultValue: "mergeStrategy must be either 'overlay' or 'replace'"
                    )
                )
            }
            strategy = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        } else {
            strategy = "overlay"
        }
        guard strategy == "overlay" || strategy == "replace" else {
            throw CmuxAgentManifestLoadError.unsupportedMergeStrategy(path: url.path, value: strategy)
        }
        // `mergeStrategy` controls how the file is applied; it is not part of
        // the decoded manifest schema. Strip it before both replacement and
        // overlay decoding so strict validation cannot mistake the control
        // key for an unknown manifest field.
        var manifestObject = object
        manifestObject.removeValue(forKey: "mergeStrategy")
        let merged: [String: Any]
        if strategy == "replace" || indexes[id] == nil {
            merged = manifestObject
        } else {
            let base = try jsonObject(from: entries[indexes[id]!].manifest)
            merged = Self.deepMerge(base, manifestObject)
        }
        let mergedData: Data
        do { mergedData = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys]) }
        catch {
            throw CmuxAgentManifestLoadError.invalidFile(
                path: url.path,
                reason: CmuxAgentManifestLocalization.reason(
                    "agentManifest.validation.cannotMergeManifest",
                    defaultValue: "Cannot merge manifest: \(error.localizedDescription)"
                )
            )
        }
        do {
            let manifest = try CmuxAgentManifestCodec.decode(data: mergedData)
            let entry = CmuxAgentManifestEntry(manifest: manifest, source: .user, sourcePath: url.path)
            if let index = indexes[id] {
                entries[index] = entry
            } else {
                indexes[id] = entries.count
                entries.append(entry)
            }
        } catch let error as CmuxAgentManifestValidationError {
            throw CmuxAgentManifestLoadError.invalidFile(path: url.path, reason: error.description)
        } catch {
            throw CmuxAgentManifestLoadError.invalidFile(path: url.path, reason: error.localizedDescription)
        }
    }

    private func jsonObject(from manifest: CmuxAgentDetectionManifest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(manifest)
        guard let object = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw CmuxAgentManifestLoadError.invalidFile(
                path: "bundle",
                reason: CmuxAgentManifestLocalization.reason(
                    "agentManifest.validation.internalEncoding",
                    defaultValue: "Internal manifest encoding failed"
                )
            )
        }
        return object
    }

    private static func deepMerge(_ base: [String: Any], _ override: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in override {
            if let baseValue = result[key] as? [String: Any], let overrideValue = value as? [String: Any] {
                result[key] = deepMerge(baseValue, overrideValue)
            } else {
                result[key] = value
            }
        }
        result.removeValue(forKey: "mergeStrategy")
        return result
    }
}

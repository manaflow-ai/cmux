public import Foundation
import CryptoKit

/// One plugin found under the install root.
public struct CmuxInstalledPlugin: Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        /// Installed but never enabled, or disabled by the user.
        case disabled
        /// Enabled and the manifest matches what the user enabled.
        case enabled
        /// Enabled once, but the manifest changed since. Inactive until re-enabled.
        case changed
    }

    public let manifest: CmuxPluginManifest
    /// The resolved plugin directory (the link target for `plugin link`).
    public let directory: URL
    /// True when the install entry is a symlink created by `plugin link`.
    public let isLinked: Bool
    /// SHA-256 of the manifest bytes, hex encoded.
    public let fingerprint: String
    public let status: Status

    public var name: String { manifest.name }
    public var isActive: Bool { status == .enabled }
    public var manifestURL: URL { directory.appendingPathComponent(CmuxPluginManifest.fileName) }
}

/// A plugin directory that could not be loaded, reported by `plugin list`.
public struct CmuxPluginLoadProblem: Equatable, Sendable {
    public let name: String
    public let message: String
}

/// Snapshot of installed extension plugins and their enablement.
public struct CmuxPluginCatalog: Equatable, Sendable {
    /// Matches the cmux-tui manager's per-root inspection bound.
    static let maximumEntries = 256

    public let plugins: [CmuxInstalledPlugin]
    public let problems: [CmuxPluginLoadProblem]

    public init(plugins: [CmuxInstalledPlugin] = [], problems: [CmuxPluginLoadProblem] = []) {
        self.plugins = plugins
        self.problems = problems
    }

    public var activePlugins: [CmuxInstalledPlugin] {
        plugins.filter(\.isActive)
    }

    public func plugin(named name: String) -> CmuxInstalledPlugin? {
        plugins.first { $0.name == name }
    }

    /// Scans the install root. Hidden entries (install transactions) are
    /// skipped; each problem is reported instead of aborting the scan.
    public static func load(
        paths: CmuxPluginPaths,
        fileManager: FileManager = .default
    ) -> CmuxPluginCatalog {
        let root = paths.installRoot
        let entries: [String]
        do {
            entries = try fileManager.contentsOfDirectory(atPath: root.path)
        } catch {
            guard !fileManager.fileExists(atPath: root.path) else {
                return CmuxPluginCatalog(problems: [
                    CmuxPluginLoadProblem(name: root.path, message: "unable to read plugin install root")
                ])
            }
            return CmuxPluginCatalog()
        }
        let visibleEntries = entries.filter { !$0.hasPrefix(".") }
        guard visibleEntries.count <= maximumEntries else {
            return CmuxPluginCatalog(problems: [
                CmuxPluginLoadProblem(
                    name: root.path,
                    message: "more than \(maximumEntries) entries; remove unused plugins"
                ),
            ])
        }
        let enabled = CmuxPluginEnablementStore(fileURL: paths.enablementFile).load()
        var plugins: [CmuxInstalledPlugin] = []
        var problems: [CmuxPluginLoadProblem] = []
        for entry in visibleEntries.sorted() {
            do {
                plugins.append(try loadPlugin(
                    entry: entry,
                    root: root,
                    enabled: enabled,
                    fileManager: fileManager
                ))
            } catch {
                problems.append(CmuxPluginLoadProblem(name: entry, message: String(describing: error)))
            }
        }
        return CmuxPluginCatalog(plugins: plugins, problems: problems)
    }

    /// Reads and validates one plugin directory without consulting enablement.
    public static func readManifest(
        in directory: URL
    ) throws -> (manifest: CmuxPluginManifest, fingerprint: String) {
        let url = directory.appendingPathComponent(CmuxPluginManifest.fileName)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType,
              type == .typeRegular else {
            throw CmuxPluginManifestError("\(CmuxPluginManifest.fileName) is not a regular file")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw CmuxPluginManifestError("missing \(CmuxPluginManifest.fileName)")
        }
        defer { try? handle.close() }
        let data = try handle.read(upToCount: CmuxPluginManifest.maximumFileBytes + 1) ?? Data()
        guard data.count <= CmuxPluginManifest.maximumFileBytes else {
            throw CmuxPluginManifestError("manifest is larger than \(CmuxPluginManifest.maximumFileBytes / 1024) KiB")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CmuxPluginManifestError("manifest is not UTF-8")
        }
        let manifest = try CmuxPluginManifest.parse(text)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (manifest, digest)
    }

    private static func loadPlugin(
        entry: String,
        root: URL,
        enabled: [String: CmuxPluginEnablementStore.Record],
        fileManager: FileManager
    ) throws -> CmuxInstalledPlugin {
        let entryURL = root.appendingPathComponent(entry, isDirectory: true)
        let isLinked = (try? fileManager.destinationOfSymbolicLink(atPath: entryURL.path)) != nil
        let directory = entryURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CmuxPluginManifestError(isLinked ? "linked directory no longer exists" : "not a directory")
        }
        let (manifest, fingerprint) = try readManifest(in: directory)
        guard manifest.kind == .extension else {
            throw CmuxPluginManifestError("kind '\(manifest.kind.rawValue)' is managed by cmux-tui, not the app")
        }
        guard manifest.supportsMacOS else {
            throw CmuxPluginManifestError("plugin.platforms does not include macos")
        }
        guard manifest.name == entry else {
            throw CmuxPluginManifestError("directory name does not match plugin.name '\(manifest.name)'")
        }
        let status: CmuxInstalledPlugin.Status
        switch enabled[entry]?.fingerprint {
        case nil:
            status = .disabled
        case fingerprint?:
            status = .enabled
        default:
            status = .changed
        }
        return CmuxInstalledPlugin(
            manifest: manifest,
            directory: directory,
            isLinked: isLinked,
            fingerprint: fingerprint,
            status: status
        )
    }
}

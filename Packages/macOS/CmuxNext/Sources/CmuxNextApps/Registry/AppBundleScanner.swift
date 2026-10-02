public import Foundation

/// An app package on disk: a directory holding `cmux-app.json`.
public nonisolated struct AppBundle: Sendable, Hashable, Identifiable {
    public enum Source: String, Sendable, Hashable, Codable {
        /// A first-party sample shipped inside the app.
        case bundled
        /// A sideloaded development app under `<apps dir>/local/`.
        case local
    }

    public var manifest: AppManifest
    public var directory: URL
    public var source: Source
    public var id: String { manifest.id }

    public init(manifest: AppManifest, directory: URL, source: Source) {
        self.manifest = manifest
        self.directory = directory
        self.source = source
    }
}

/// Finds app packages: one level of subdirectories, each with a valid
/// manifest. Invalid ones are reported, never loaded. Local apps must use
/// the `local/` publisher; bundled ones must not.
public nonisolated enum AppBundleScanner {
    public struct Problem: Sendable, Hashable {
        public var directory: URL
        public var message: String
    }

    public static func scan(_ root: URL, source: AppBundle.Source) -> (bundles: [AppBundle], problems: [Problem]) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return ([], []) }
        var bundles: [AppBundle] = []
        var problems: [Problem] = []
        for directory in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let manifestURL = directory.appending(path: "cmux-app.json")
            guard fm.fileExists(atPath: manifestURL.path) else { continue }
            guard let data = try? Data(contentsOf: manifestURL) else {
                problems.append(Problem(directory: directory, message: "cannot read cmux-app.json"))
                continue
            }
            do {
                let manifest = try AppManifest.decode(data)
                if (source == .local) != manifest.isLocal {
                    problems.append(Problem(directory: directory, message: source == .local
                        ? "\(manifest.id): development apps use the local/ publisher"
                        : "\(manifest.id): bundled apps cannot use the local/ publisher"))
                    continue
                }
                bundles.append(AppBundle(manifest: manifest, directory: directory, source: source))
            } catch {
                problems.append(Problem(directory: directory, message: error.description))
            }
        }
        return (bundles, problems)
    }
}

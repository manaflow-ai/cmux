public import Foundation

/// An app package on disk: a directory holding `cmux-app.json` (or, for a
/// first-party package, `cmux-app.v2.json`).
public nonisolated struct AppBundle: Sendable, Hashable, Identifiable {
    public enum Source: String, Sendable, Hashable, Codable {
        /// A sample app shipped inside the app (opt-in).
        case bundled
        /// A first-party app shipped inside the app: installed by default, hideable.
        case firstParty
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
            // First-party packages may ship manifest v2 (`cmux-app.v2.json`):
            // alone (Home, App Store) or next to the v1 file the prototype
            // engine runs, which then takes v2's presentation.
            let v2URL = directory.appending(path: "cmux-app.v2.json")
            let v2 = source == .firstParty && fm.fileExists(atPath: v2URL.path) ? v2URL : nil
            guard fm.fileExists(atPath: manifestURL.path) || v2 != nil else { continue }
            do {
                var manifest: AppManifest
                if fm.fileExists(atPath: manifestURL.path) {
                    guard let data = try? Data(contentsOf: manifestURL) else {
                        problems.append(Problem(directory: directory, message: "cannot read cmux-app.json"))
                        continue
                    }
                    manifest = try AppManifest.decode(data)
                    if let v2, let data = try? Data(contentsOf: v2) {
                        let v2Manifest = try AppManifest.decodeShippedV2(data)
                        manifest.presentation = v2Manifest.presentation
                        manifest.toolbarItems = v2Manifest.toolbarItems
                    }
                } else if let v2, let data = try? Data(contentsOf: v2) {
                    manifest = try AppManifest.decodeShippedV2(data)
                } else {
                    problems.append(Problem(directory: directory, message: "cannot read cmux-app.v2.json"))
                    continue
                }
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

import CmuxNextCompat
public import Foundation

/// A local app packed for the App Store's review queue (plans/cmux-next/
/// custom-panes-DESIGN.md section 6.3): `local/<name>` becomes
/// `<publisher>/<name>`, and every package file (no hidden file, no
/// `node_modules`, no symlink) is sent as base64 with the rewritten manifest.
///
/// The checks are the ones the registry and the supervisor make later, so a
/// person hears them before sending: the publisher's form, the GitHub
/// repository owned by that publisher (cmux-app-manifest `repository.required`
/// and `publisher.mismatch`), and the bundle limits.
public nonisolated struct AppRegistrySubmission: Sendable {
    public static let maxFiles = 200
    public static let maxBytes = 2 * 1024 * 1024
    /// In the daemon catalog's order (`catalog::manifest_file`): `cmux-app.json` wins when both exist.
    static let manifestFiles = ["cmux-app.json", "cmux-app.v2.json"]

    /// The manifest as submitted, with its new id.
    public let manifest: AppJSON
    /// Package path to its bytes, base64; the manifest file holds `manifest`.
    public let files: [String: String]

    public var app: String { manifest["id"]?.stringValue ?? "" }
    public var version: String { manifest["version"]?.stringValue ?? "" }

    /// Packs the package at `bundle` of the local app `localID` under `publisher`.
    public init(bundle: URL, localID: String, publisher: String) throws(Failure) {
        guard localID.hasPrefix("local/") else { throw Failure("only a local app can be submitted") }
        guard publisher.range(of: #"^[a-z0-9][a-z0-9-]{0,38}$"#, options: .regularExpression) != nil,
              !["cmux", "manaflow-ai", "local"].contains(publisher)
        else { throw Failure("\(publisher) is not a publisher name you can use") }
        let root = bundle.standardizedFileURL.resolvingSymlinksInPath()
        guard let manifestFile = Self.manifestFiles.first(where: {
            FileManager.checked.fileExists(atPath: root.appendingPathComponent($0).path)
        }) else { throw Failure("the app has no cmux-app.json") }
        guard let data = try? Data(blockingContentsOf: root.appendingPathComponent(manifestFile)),
              var fields = (try? AppJSON.parse(data))?.objectValue
        else { throw Failure("\(manifestFile) is not valid JSON") }
        guard fields["id"]?.stringValue == localID else { throw Failure("\(manifestFile) names another app") }
        let owner = Self.repositoryOwner(fields["repository"]?.stringValue)
        guard owner == publisher else {
            throw Failure("set \"repository\" in \(manifestFile) to https://github.com/\(publisher)/<repository> before submitting")
        }
        fields["id"] = .string(publisher + "/" + localID.dropFirst("local/".count))
        let manifest = AppJSON.object(fields)

        var files = try Self.packageFiles(root, skipping: Set(Self.manifestFiles))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let manifestData = try? encoder.encode(manifest) else { throw Failure("the manifest cannot be written") }
        files[manifestFile] = manifestData
        guard files.count <= Self.maxFiles else { throw Failure("an app has at most \(Self.maxFiles) files") }
        guard files.values.reduce(0, { $0 + $1.count }) <= Self.maxBytes else { throw Failure("an app is at most 2 MiB") }
        self.manifest = manifest
        self.files = files.mapValues { $0.base64EncodedString() }
    }

    /// The owner of a `https://github.com/<owner>/<repo>` URL, lowercased.
    static func repositoryOwner(_ repository: String?) -> String? {
        guard let repository, repository.hasPrefix("https://github.com/") else { return nil }
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count > 4 && !parts[3].isEmpty ? parts[3].lowercased() : nil
    }

    /// Every regular file under `root` by its package path, past the limits only by one file.
    private static func packageFiles(_ root: URL, skipping: Set<String>) throws(Failure) -> [String: Data] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let walk = FileManager.checked.enumerator(at: root, includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { throw Failure("the app folder cannot be read") }
        var files: [String: Data] = [:]
        var total = 0
        for case let url as URL in walk {
            let values = try? url.blockingResourceValues(forKeys: Set(keys))
            if url.lastPathComponent == "node_modules" {
                walk.skipDescendants()
                continue
            }
            guard values?.isSymbolicLink != true, values?.isRegularFile == true else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            guard !skipping.contains(path) else { continue }
            guard let data = try? Data(blockingContentsOf: url) else { throw Failure("\(path) cannot be read") }
            files[path] = data
            total += data.count
            guard files.count <= maxFiles, total <= maxBytes else {
                throw Failure(files.count > maxFiles ? "an app has at most \(maxFiles) files" : "an app is at most 2 MiB")
            }
        }
        return files
    }

    /// Why the app cannot be submitted, for the page's error line.
    public struct Failure: Error, Sendable, Equatable {
        public let message: String
        init(_ message: String) { self.message = message }
    }
}

import CryptoKit
import Foundation

/// Validates and snapshots unpacked MV3 extensions into a profile-owned path.
/// Stable directory identity preserves Chrome's derived extension ID across
/// restarts; content updates replace only that profile's snapshot atomically.
actor ChromiumExtensionStore {
    private let storage: ChromiumOwnedStorage
    private let fileManager: FileManager

    init(storage: ChromiumOwnedStorage) {
        self.storage = storage
        fileManager = storage.fileManager
    }

    func prepare(directories: [String], profileID: UUID) throws -> [URL] {
        guard directories.count <= 32 else {
            throw failure("", "browser.chromium.extensions.tooMany", "Configure at most 32 unpacked extensions.")
        }
        var prepared: [URL] = []
        for directory in directories {
            try Task.checkCancellation()
            guard directory.hasPrefix("/") || directory.hasPrefix("~/") else {
                throw failure(directory, "browser.chromium.extensions.directory", "Choose an existing absolute directory path without commas.")
            }
            let source = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
                .resolvingSymlinksInPath().standardizedFileURL
            try validate(source)
            let identity = SHA256.hash(data: Data(source.path.utf8)).map { String(format: "%02x", $0) }.joined()
            let root = try storage.applicationDirectory()
                .appendingPathComponent("ChromiumExtensions", isDirectory: true)
                .appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let identityRoot = root.appendingPathComponent(identity, isDirectory: true)
            try fileManager.createDirectory(at: identityRoot, withIntermediateDirectories: true)
            let destination = identityRoot.appendingPathComponent(try contentDigest(source), isDirectory: true)
            if prepared.contains(destination) { continue }
            if fileManager.fileExists(atPath: destination.path) {
                try validate(destination)
                prepared.append(destination)
                continue
            }
            let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
            defer { try? fileManager.removeItem(at: staging) }
            do {
                try fileManager.copyItem(at: source, to: staging)
                try validate(staging)
                try installIdentity(in: staging, identityRoot: identityRoot)
                do { try fileManager.moveItem(at: staging, to: destination) }
                catch {
                    guard fileManager.fileExists(atPath: destination.path) else { throw error }
                    try validate(destination)
                }
            } catch let error as ChromiumExtensionError { throw error }
            catch {
                throw failure(
                    source.path,
                    "browser.chromium.extensions.prepare",
                    "Could not prepare the extension. Check the directory and try again."
                )
            }
            prepared.append(destination)
        }
        return prepared
    }

    func validate(_ root: URL) throws {
        var isDirectory: ObjCBool = false
        guard root.isFileURL, root.path.hasPrefix("/"), !root.path.contains(","),
              fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw failure(root.path, "browser.chromium.extensions.directory", "Choose an existing absolute directory path without commas.")
        }
        let manifestURL = root.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL), data.count <= 1024 * 1024,
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              manifest["manifest_version"] as? Int == 3,
              let name = manifest["name"] as? String, !name.isEmpty,
              let version = manifest["version"] as? String, validVersion(version) else {
            throw failure(root.path, "browser.chromium.extensions.manifest", "Provide a valid manifest.json with manifest_version 3, name, and version.")
        }
        var paths: [String] = []
        if let background = manifest["background"] as? [String: Any] {
            guard let worker = background["service_worker"] as? String else {
                throw failure(root.path, "browser.chromium.extensions.worker", "MV3 background scripts must declare background.service_worker.")
            }
            paths.append(worker)
        }
        if let scripts = manifest["content_scripts"] as? [[String: Any]] {
            for script in scripts {
                paths += (script["js"] as? [String] ?? []) + (script["css"] as? [String] ?? [])
            }
        }
        for path in paths {
            let file = root.appendingPathComponent(path).standardizedFileURL
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
                  fileManager.isReadableFile(atPath: file.path) else {
                throw failure(root.path, "browser.chromium.extensions.script", "Every declared content script and service worker must be a readable file inside the extension.")
            }
        }
        let canonicalRoot = root.resolvingSymlinksInPath().path
        var bytes = 0
        var count = 0
        guard let entries = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey]) else {
            throw failure(root.path, "browser.chromium.extensions.directory", "Choose an existing absolute directory path without commas.")
        }
        for case let file as URL in entries {
            try Task.checkCancellation()
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            count += 1
            bytes += values.fileSize ?? 0
            guard values.isSymbolicLink != true,
                  file.resolvingSymlinksInPath().path.hasPrefix(canonicalRoot + "/"),
                  count <= 20_000, bytes <= 256 * 1024 * 1024 else {
                throw failure(root.path, "browser.chromium.extensions.contents", "Remove symbolic links and keep the extension below 20,000 files and 256 MB.")
            }
        }
    }

    private func contentDigest(_ root: URL) throws -> String {
        let entries = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        var files: [URL] = []
        guard let entries else { throw CocoaError(.fileReadNoPermission) }
        for case let file as URL in entries {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { files.append(file) }
        }
        var hash = SHA256()
        for file in files.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            hash.update(data: Data(file.path.dropFirst(root.path.count).utf8))
            hash.update(data: try Data(contentsOf: file))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func installIdentity(in directory: URL, identityRoot: URL) throws {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any] ?? [:]
        guard manifest["key"] == nil else { return }
        let keyURL = identityRoot.appendingPathComponent("public-key.der")
        if !fileManager.fileExists(atPath: keyURL.path) {
            let key = P256.Signing.PrivateKey().publicKey.derRepresentation
            do { try key.write(to: keyURL, options: .withoutOverwriting) }
            catch { guard fileManager.fileExists(atPath: keyURL.path) else { throw error } }
        }
        manifest["key"] = try Data(contentsOf: keyURL).base64EncodedString()
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL, options: .atomic)
    }

    private func validVersion(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        return (1...4).contains(parts.count) && parts.allSatisfy {
            !$0.isEmpty && $0.allSatisfy(\.isNumber) && UInt16($0) != nil
        }
    }

    private func failure(_ path: String, _ key: StaticString, _ fallback: String.LocalizationValue) -> ChromiumExtensionError {
        ChromiumExtensionError(path: path, reason: String(localized: key, defaultValue: fallback, bundle: .module))
    }
}

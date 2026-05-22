import CryptoKit
import Foundation

enum ExtensionBundleResolveError: Error, LocalizedError {
    case missingBundle(String)
    case missingIndex(String)
    case disallowedBundle(String)
    case invalidManifest(String)
    case unreadableBundle(String)

    var errorDescription: String? {
        switch self {
        case .missingBundle(let path):
            return "Extension bundle not found: \(path)"
        case .missingIndex(let path):
            return "Extension bundle must contain index.html: \(path)"
        case .disallowedBundle(let path):
            return "Extension bundle is outside the allowed extension roots: \(path)"
        case .invalidManifest(let path):
            return "Extension manifest must be a JSON object if present: \(path)"
        case .unreadableBundle(let path):
            return "Extension bundle could not be read safely: \(path)"
        }
    }

    var userFacingMessage: String {
        switch self {
        case .missingBundle:
            return String(
                localized: "extensionPanel.restore.blocked.missingBundleFile",
                defaultValue: "The extension bundle could not be found. Choose the bundle again or remove this extension pane."
            )
        case .missingIndex:
            return String(
                localized: "extensionPanel.restore.blocked.missingIndex",
                defaultValue: "The extension bundle must contain an index.html file."
            )
        case .disallowedBundle:
            return String(
                localized: "extensionPanel.restore.blocked.disallowed",
                defaultValue: "This extension bundle is not in an approved location. Move it to your cmux extensions folder and try again."
            )
        case .invalidManifest:
            return String(
                localized: "extensionPanel.restore.blocked.invalidManifest",
                defaultValue: "The extension manifest is invalid. Fix manifest.json or remove it and try again."
            )
        case .unreadableBundle:
            return String(
                localized: "extensionPanel.restore.blocked.unreadable",
                defaultValue: "cmux could not safely read this extension bundle. Check its files and permissions, then try again."
            )
        }
    }

    var bridgeReasonCode: String {
        switch self {
        case .missingBundle:
            return "missing_bundle"
        case .missingIndex:
            return "missing_index"
        case .disallowedBundle:
            return "disallowed_bundle"
        case .invalidManifest:
            return "invalid_manifest"
        case .unreadableBundle:
            return "unreadable_bundle"
        }
    }

    static func userFacingMessage(for error: Error) -> String {
        guard let resolveError = error as? ExtensionBundleResolveError else {
            return String(
                localized: "extensionPanel.restore.blocked.unknown",
                defaultValue: "cmux could not restore this extension bundle."
            )
        }
        return resolveError.userFacingMessage
    }

    static var missingBundlePathMessage: String {
        String(
            localized: "extensionPanel.restore.blocked.missingBundle",
            defaultValue: "The extension surface is missing a bundle path."
        )
    }

    static var untrustedBundleMessage: String {
        String(
            localized: "extensionPanel.restore.blocked.untrusted",
            defaultValue: "The extension bundle changed or is no longer trusted."
        )
    }

    static func bridgeReasonCode(for error: Error) -> String {
        guard let resolveError = error as? ExtensionBundleResolveError else {
            return "unknown"
        }
        return resolveError.bridgeReasonCode
    }
}

struct ExtensionBundleManifest: Equatable, Sendable {
    let identifier: String?
    let name: String?
    let version: String?
}

struct ExtensionBundleDescriptor: Equatable, Sendable {
    let bundleURL: URL
    let indexURL: URL
    let displayName: String
    let manifest: ExtensionBundleManifest?
    let contentHash: String

    var bundlePath: String { bundleURL.path }

    static func resolve(
        path rawPath: String,
        allowedRoots: [String]? = defaultAllowedRootPaths(),
        fileManager: FileManager = .default
    ) throws -> ExtensionBundleDescriptor {
        let expandedPath = (rawPath as NSString).expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expandedPath.isEmpty else {
            throw ExtensionBundleResolveError.missingBundle(rawPath)
        }

        let inputURL = URL(fileURLWithPath: expandedPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: inputURL.path, isDirectory: &isDirectory) else {
            throw ExtensionBundleResolveError.missingBundle(inputURL.path)
        }

        let bundleURL: URL
        let indexURL: URL
        if isDirectory.boolValue {
            bundleURL = inputURL
            indexURL = inputURL.appendingPathComponent("index.html", isDirectory: false)
        } else if inputURL.lastPathComponent == "index.html" {
            bundleURL = inputURL.deletingLastPathComponent()
            indexURL = inputURL
        } else {
            throw ExtensionBundleResolveError.missingIndex(inputURL.path)
        }

        if let allowedRoots, !allowedRoots.isEmpty {
            let canonicalAllowedRoots = allowedRoots
                .map { ($0 as NSString).expandingTildeInPath }
                .map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
                .filter { !$0.isEmpty && $0 != "/" }
            guard canonicalAllowedRoots.contains(where: { isPath(bundleURL.path, containedIn: $0) }) else {
                throw ExtensionBundleResolveError.disallowedBundle(bundleURL.path)
            }
        }

        var isIndexDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: indexURL.path, isDirectory: &isIndexDirectory),
              !isIndexDirectory.boolValue else {
            throw ExtensionBundleResolveError.missingIndex(bundleURL.path)
        }
        guard isPath(indexURL.resolvingSymlinksInPath().path, containedIn: bundleURL.path) else {
            throw ExtensionBundleResolveError.disallowedBundle(indexURL.path)
        }

        let manifest = try manifest(for: bundleURL, fileManager: fileManager)
        let contentHash = try contentHash(for: bundleURL, fileManager: fileManager)
        return ExtensionBundleDescriptor(
            bundleURL: bundleURL,
            indexURL: indexURL,
            displayName: displayName(for: bundleURL, manifest: manifest),
            manifest: manifest,
            contentHash: contentHash
        )
    }

    static func resolveUserSelected(path rawPath: String) throws -> ExtensionBundleDescriptor {
        try resolve(path: rawPath, allowedRoots: defaultAllowedRootPaths())
    }

    static func defaultAllowedRootPaths(fileManager: FileManager = .default) -> [String] {
        var roots = [
            (NSHomeDirectory() as NSString).appendingPathComponent(".cmux/extensions")
        ]
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            roots.append(appSupport.appendingPathComponent("cmux/extensions", isDirectory: true).path)
        }
        return roots
    }

    private static func manifest(for bundleURL: URL, fileManager: FileManager) throws -> ExtensionBundleManifest? {
        let manifestURL = bundleURL.appendingPathComponent("manifest.json", isDirectory: false)
        guard fileManager.fileExists(atPath: manifestURL.path) else { return nil }
        let readURL: URL
        if let linkDestination = try? fileManager.destinationOfSymbolicLink(atPath: manifestURL.path) {
            let resolvedPath: String
            if linkDestination.hasPrefix("/") {
                resolvedPath = linkDestination
            } else {
                resolvedPath = (manifestURL.deletingLastPathComponent().path as NSString)
                    .appendingPathComponent(linkDestination)
            }
            let resolvedURL = URL(fileURLWithPath: resolvedPath).standardizedFileURL.resolvingSymlinksInPath()
            guard isPath(resolvedURL.path, containedIn: bundleURL.path) else {
                throw ExtensionBundleResolveError.disallowedBundle(manifestURL.path)
            }
            readURL = resolvedURL
        } else {
            readURL = manifestURL
        }
        let data = try Data(contentsOf: readURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExtensionBundleResolveError.invalidManifest(manifestURL.path)
        }
        return ExtensionBundleManifest(
            identifier: nonEmptyString(object["id"] ?? object["identifier"]),
            name: nonEmptyString(object["name"]),
            version: nonEmptyString(object["version"])
        )
    }

    private static func displayName(for bundleURL: URL, manifest: ExtensionBundleManifest?) -> String {
        if let name = manifest?.name {
            return name
        }

        let folderName = bundleURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !folderName.isEmpty {
            return folderName
        }
        return String(localized: "extensionPanel.defaultTitle", defaultValue: "Extension")
    }

    private static func contentHash(for bundleURL: URL, fileManager: FileManager) throws -> String {
        guard let enumerator = fileManager.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isRegularFileKey],
            options: []
        ) else {
            throw ExtensionBundleResolveError.unreadableBundle(bundleURL.path)
        }

        let rootPath = bundleURL.path
        var fileURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            let canonicalFileURL = fileURL.standardizedFileURL.resolvingSymlinksInPath()
            guard isPath(canonicalFileURL.path, containedIn: rootPath) else {
                throw ExtensionBundleResolveError.disallowedBundle(fileURL.path)
            }
            let resourceValues = try canonicalFileURL.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isRegularFileKey])
            if resourceValues.isDirectory == true, resourceValues.isPackage == true {
                throw ExtensionBundleResolveError.unreadableBundle(fileURL.path)
            }
            if resourceValues.isRegularFile == true {
                fileURLs.append(canonicalFileURL)
            }
        }

        var hasher = SHA256()
        for fileURL in fileURLs.sorted(by: { $0.path < $1.path }) {
            let relativePath = String(fileURL.path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let relativeData = relativePath.data(using: .utf8) else {
                throw ExtensionBundleResolveError.unreadableBundle(fileURL.path)
            }
            hasher.update(data: relativeData)
            hasher.update(data: Data([0]))
            hasher.update(data: try Data(contentsOf: fileURL))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isPath(_ path: String, containedIn root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }
}

// Sendable safety: `defaults` access is serialized through `lock`.
final class ExtensionBundleTrustStore: @unchecked Sendable {
    static let shared = ExtensionBundleTrustStore()

    private let defaults: UserDefaults
    private let defaultsKey = "extensionPanel.trustedBundleHashes"
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func trust(_ descriptor: ExtensionBundleDescriptor) {
        lock.lock()
        defer { lock.unlock() }
        var trusted = trustedHashesLocked()
        trusted[descriptor.bundlePath] = descriptor.contentHash
        defaults.set(trusted, forKey: defaultsKey)
    }

    func isTrusted(_ descriptor: ExtensionBundleDescriptor) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return trustedHashesLocked()[descriptor.bundlePath] == descriptor.contentHash
    }

    private func trustedHashesLocked() -> [String: String] {
        defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }
}

import Foundation

enum SocketPathMarkerFiles {
    static let stableAppSupportFileName = "last-socket-path"
    static let stableTmpPath = "/tmp/cmux-last-socket-path"

    private enum Variant: Equatable {
        case stable
        case nightly(slug: String?)
        case staging(slug: String?)
        case dev(slug: String?)

        var appSupportFileName: String {
            switch self {
            case .stable:
                return SocketPathMarkerFiles.stableAppSupportFileName
            case .nightly(let slug):
                if let slug {
                    return "nightly-\(slug)-last-socket-path"
                }
                return "nightly-last-socket-path"
            case .staging(let slug):
                if let slug {
                    return "staging-\(slug)-last-socket-path"
                }
                return "staging-last-socket-path"
            case .dev(let slug):
                if let slug {
                    return "dev-\(slug)-last-socket-path"
                }
                return "dev-last-socket-path"
            }
        }

        var tmpPath: String {
            switch self {
            case .stable:
                return SocketPathMarkerFiles.stableTmpPath
            case .nightly(let slug):
                if let slug {
                    return "/tmp/cmux-nightly-\(slug)-last-socket-path"
                }
                return "/tmp/cmux-nightly-last-socket-path"
            case .staging(let slug):
                if let slug {
                    return "/tmp/cmux-staging-\(slug)-last-socket-path"
                }
                return "/tmp/cmux-staging-last-socket-path"
            case .dev(let slug):
                if let slug {
                    return "/tmp/cmux-dev-\(slug)-last-socket-path"
                }
                return "/tmp/cmux-dev-last-socket-path"
            }
        }
    }

    static func appSupportFileURL(
        fileName: String = stableAppSupportFileName,
        appSupportDirectory: URL?
    ) -> URL? {
        appSupportDirectory?.appendingPathComponent(fileName, isDirectory: false)
    }

    static func paths(
        bundleIdentifier: String?,
        environment: [String: String],
        appSupportDirectory: URL?
    ) -> [String] {
        let variant = variant(bundleIdentifier: bundleIdentifier, environment: environment)
        var candidates: [String] = []
        if let appSupportPath = appSupportFileURL(
            fileName: variant.appSupportFileName,
            appSupportDirectory: appSupportDirectory
        )?.path {
            candidates.append(appSupportPath)
        }
        candidates.append(variant.tmpPath)
        return dedupe(candidates)
    }

    private static func variant(
        bundleIdentifier: String?,
        environment: [String: String]
    ) -> Variant {
        let bundleId = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if bundleId == "com.cmuxterm.app.nightly" {
            return .nightly(slug: nil)
        }
        if bundleId.hasPrefix("com.cmuxterm.app.nightly.") {
            return .nightly(slug: bundleSuffixSlug(bundleId, prefix: "com.cmuxterm.app.nightly."))
        }
        if bundleId == "com.cmuxterm.app.staging" {
            return .staging(slug: nil)
        }
        if bundleId.hasPrefix("com.cmuxterm.app.staging.") {
            return .staging(slug: bundleSuffixSlug(bundleId, prefix: "com.cmuxterm.app.staging."))
        }
        if bundleId == SocketControlSettings.baseDebugBundleIdentifier {
            if let tag = SocketControlSettings.launchTag(environment: environment) {
                return .dev(slug: sanitizeSocketSlug(tag))
            }
            return .dev(slug: nil)
        }
        if bundleId.hasPrefix("\(SocketControlSettings.baseDebugBundleIdentifier).") {
            return .dev(slug: bundleSuffixSlug(bundleId, prefix: "\(SocketControlSettings.baseDebugBundleIdentifier)."))
        }
        return .stable
    }

    private static func bundleSuffixSlug(_ bundleIdentifier: String, prefix: String) -> String? {
        let suffix = String(bundleIdentifier.dropFirst(prefix.count))
        return sanitizeSocketSlug(suffix)
    }

    static func sanitizeSocketSlug(_ raw: String) -> String? {
        let slug = raw
            .lowercased()
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return slug.isEmpty ? nil : slug
    }

    private static func dedupe(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for value in values where seen.insert(value).inserted {
            ordered.append(value)
        }
        return ordered
    }
}

extension SocketControlSettings {
    static func recordLastSocketPath(
        _ path: String,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let payload = Data((path + "\n").utf8)
        for filePath in lastSocketPathFiles(bundleIdentifier: bundleIdentifier, environment: environment) {
            writeSocketPathMarker(payload, to: filePath)
        }
    }

    static func lastSocketPathFileURL(fileManager: FileManager = .default) -> URL? {
        SocketPathMarkerFiles.appSupportFileURL(
            appSupportDirectory: stableSocketDirectoryURL(fileManager: fileManager)
        )
    }

    static func lastSocketPathFiles(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [String] {
        SocketPathMarkerFiles.paths(
            bundleIdentifier: bundleIdentifier,
            environment: environment,
            appSupportDirectory: stableSocketDirectoryURL(fileManager: fileManager)
        )
    }

    private static func writeSocketPathMarker(_ payload: Data, to filePath: String) {
        let fileURL = URL(fileURLWithPath: filePath)
        let parentURL = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? payload.write(to: fileURL, options: .atomic)
    }
}

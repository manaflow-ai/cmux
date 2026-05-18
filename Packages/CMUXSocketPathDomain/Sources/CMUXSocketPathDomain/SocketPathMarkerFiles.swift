import Foundation

public enum SocketPathVariant: Equatable {
    case stable
    case nightly(slug: String?)
    case staging(slug: String?)
    case dev(slug: String?)

    public var appSupportFileName: String {
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

    public var tmpPath: String {
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

    public var isDev: Bool {
        if case .dev = self { return true }
        return false
    }
}

public enum SocketPathMarkerFiles {
    public static let stableAppSupportFileName = "last-socket-path"
    public static let stableTmpPath = "/tmp/cmux-last-socket-path"
    public static let releaseBundleIdentifier = "com.cmuxterm.app"
    public static let nightlyBundleIdentifier = "com.cmuxterm.app.nightly"
    public static let stagingBundleIdentifier = "com.cmuxterm.app.staging"
    public static let defaultBaseDebugBundleIdentifier = "com.cmuxterm.app.debug"
    public static let defaultDebugSocketPath = "/tmp/cmux-debug.sock"
    public static let defaultNightlySocketPath = "/tmp/cmux-nightly.sock"
    public static let defaultStagingSocketPath = "/tmp/cmux-staging.sock"
    public static let releaseSocketFileName = "\(releaseBundleIdentifier).sock"
    public static let legacyReleaseSocketFileName = "cmux.sock"
    public static let nightlySocketFileName = "\(nightlyBundleIdentifier).sock"
    public static let stagingSocketFileName = "\(stagingBundleIdentifier).sock"
    public static let devSocketFileName = "\(releaseBundleIdentifier).dev.sock"

    public static func appSupportFileURL(
        fileName: String = stableAppSupportFileName,
        appSupportDirectory: URL?
    ) -> URL? {
        appSupportDirectory?.appendingPathComponent(fileName, isDirectory: false)
    }

    public static func paths(
        bundleIdentifier: String?,
        environment: [String: String],
        appSupportDirectory: URL?,
        baseDebugBundleIdentifier: String = defaultBaseDebugBundleIdentifier
    ) -> [String] {
        let variant = variant(
            bundleIdentifier: bundleIdentifier,
            environment: environment,
            baseDebugBundleIdentifier: baseDebugBundleIdentifier
        )
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

    public static func variant(
        bundleIdentifier: String?,
        environment: [String: String],
        baseDebugBundleIdentifier: String = defaultBaseDebugBundleIdentifier
    ) -> SocketPathVariant {
        let bundleId = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if bundleId == nightlyBundleIdentifier {
            return .nightly(slug: nil)
        }
        let nightlyPrefix = nightlyBundleIdentifier + "."
        if bundleId.hasPrefix(nightlyPrefix) {
            return .nightly(slug: bundleSuffixSlug(bundleId, prefix: nightlyPrefix))
        }
        if bundleId == stagingBundleIdentifier {
            return .staging(slug: nil)
        }
        let stagingPrefix = stagingBundleIdentifier + "."
        if bundleId.hasPrefix(stagingPrefix) {
            return .staging(slug: bundleSuffixSlug(bundleId, prefix: stagingPrefix))
        }
        if bundleId == baseDebugBundleIdentifier {
            if let tag = normalized(environment["CMUX_TAG"]),
               let slug = sanitizeSocketSlug(tag) {
                return .dev(slug: slug)
            }
            return .dev(slug: nil)
        }
        if bundleId.hasPrefix("\(baseDebugBundleIdentifier).") {
            return .dev(slug: bundleSuffixSlug(bundleId, prefix: "\(baseDebugBundleIdentifier)."))
        }
        return .stable
    }

    public static func defaultSocketPath(
        bundleIdentifier: String?,
        environment: [String: String],
        isDebugBuild: Bool,
        stableSocketPath: String,
        appSupportDirectory: URL? = nil,
        baseDebugBundleIdentifier: String = defaultBaseDebugBundleIdentifier,
        debugSocketPath: String = defaultDebugSocketPath,
        nightlySocketPath: String = defaultNightlySocketPath,
        stagingSocketPath: String = defaultStagingSocketPath
    ) -> String {
        let resolvedVariant = variant(
            bundleIdentifier: bundleIdentifier,
            environment: environment,
            baseDebugBundleIdentifier: baseDebugBundleIdentifier
        )
        let effectiveVariant: SocketPathVariant
        if case .stable = resolvedVariant, isDebugBuild {
            effectiveVariant = .dev(slug: nil)
        } else {
            effectiveVariant = resolvedVariant
        }

        if let appSupportDirectory, effectiveVariant != .stable {
            return socketPath(
                fileName: socketFileName(for: effectiveVariant),
                directory: appSupportDirectory
            )
        }

        switch effectiveVariant {
        case .stable:
            return stableSocketPath
        case .nightly(let slug):
            if let slug {
                return "/tmp/cmux-nightly-\(slug).sock"
            }
            return nightlySocketPath
        case .staging(let slug):
            if let slug {
                return "/tmp/cmux-staging-\(slug).sock"
            }
            return stagingSocketPath
        case .dev(let slug):
            if let slug {
                return "/tmp/cmux-debug-\(slug).sock"
            }
            return debugSocketPath
        }
    }

    public static func socketFileName(for variant: SocketPathVariant) -> String {
        switch variant {
        case .stable:
            return releaseSocketFileName
        case .nightly:
            return nightlySocketFileName
        case .staging:
            return stagingSocketFileName
        case .dev(let slug):
            if let slug {
                return "\(releaseBundleIdentifier).dev.\(slug).sock"
            }
            return devSocketFileName
        }
    }

    public static func socketPath(fileName: String, directory: URL) -> String {
        let candidate = directory.appendingPathComponent(fileName, isDirectory: false).path
        guard candidate.utf8.count > unixSocketPathMaxLength else {
            return candidate
        }
        return directory
            .appendingPathComponent(shortenedSocketFileName(fileName, directoryPath: directory.path), isDirectory: false)
            .path
    }

    public static func sanitizeSocketSlug(_ raw: String) -> String? {
        let slug = raw
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? nil : slug
    }

    private static func bundleSuffixSlug(_ bundleIdentifier: String, prefix: String) -> String? {
        let suffix = String(bundleIdentifier.dropFirst(prefix.count))
        return sanitizeSocketSlug(suffix)
    }

    private static var unixSocketPathMaxLength: Int {
        #if os(Linux)
        return 107
        #else
        return 103
        #endif
    }

    private static func shortenedSocketFileName(_ fileName: String, directoryPath: String) -> String {
        let separatorLength = 1
        let budget = unixSocketPathMaxLength - directoryPath.utf8.count - separatorLength
        let suffix = ".sock"
        let hashSuffixLength = 9
        guard fileName.utf8.count > budget, budget >= suffix.utf8.count + hashSuffixLength + 1 else {
            return fileName
        }

        let stem = fileName.hasSuffix(suffix) ? String(fileName.dropLast(suffix.count)) : fileName
        let hashSuffix = "-\(fnv1a32Hex(fileName))"
        let stemBudget = budget - hashSuffix.utf8.count - suffix.utf8.count
        let shortenedStem = String(stem.prefix(stemBudget)).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        let safeStem = shortenedStem.isEmpty ? "cmux" : shortenedStem
        return "\(safeStem)\(hashSuffix)\(suffix)"
    }

    private static func fnv1a32Hex(_ value: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in value.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return String(format: "%08x", hash)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

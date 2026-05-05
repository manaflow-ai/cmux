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
    public static let defaultBaseDebugBundleIdentifier = "com.cmuxterm.app.debug"

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

    public static func sanitizeSocketSlug(_ raw: String) -> String? {
        let slug = raw
            .lowercased()
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return slug.isEmpty ? nil : slug
    }

    private static func bundleSuffixSlug(_ bundleIdentifier: String, prefix: String) -> String? {
        let suffix = String(bundleIdentifier.dropFirst(prefix.count))
        return sanitizeSocketSlug(suffix)
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

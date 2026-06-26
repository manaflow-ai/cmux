public import Foundation
import AppKit

/// Resolves which applications can open a file and in what order, injecting the
/// four `NSWorkspace`/`Bundle` lookups as closures so the ordering and
/// deduplication logic is testable without touching Launch Services.
public struct FileExternalOpenApplicationResolver: Sendable {
    /// The system-default application for a file, if any.
    public var defaultApplicationURL: @Sendable (URL) -> URL?
    /// All applications Launch Services reports can open a file.
    public var applicationURLs: @Sendable (URL) -> [URL]
    /// Human-readable name for an application bundle.
    public var displayName: @Sendable (URL) -> String
    /// Whether an application should be offered (excludes cmux itself).
    public var shouldIncludeApplication: @Sendable (URL) -> Bool

    public init(
        defaultApplicationURL: @escaping @Sendable (URL) -> URL?,
        applicationURLs: @escaping @Sendable (URL) -> [URL],
        displayName: @escaping @Sendable (URL) -> String,
        shouldIncludeApplication: @escaping @Sendable (URL) -> Bool
    ) {
        self.defaultApplicationURL = defaultApplicationURL
        self.applicationURLs = applicationURLs
        self.displayName = displayName
        self.shouldIncludeApplication = shouldIncludeApplication
    }

    /// The production resolver backed by `NSWorkspace` and `Bundle`.
    public static let live = FileExternalOpenApplicationResolver(
        defaultApplicationURL: { NSWorkspace.shared.urlForApplication(toOpen: $0) },
        applicationURLs: { NSWorkspace.shared.urlsForApplications(toOpen: $0) },
        displayName: { Self.liveDisplayName(for: $0) },
        shouldIncludeApplication: { Self.shouldIncludeLiveApplication($0) }
    )

    /// Default app first, then the remaining apps, deduplicated by bundle path.
    public func applications(for fileURL: URL) -> [FileExternalOpenApplication] {
        let defaultURL = defaultApplicationURL(fileURL).flatMap { url in
            shouldIncludeApplication(url) ? url : nil
        }
        let defaultIdentity = defaultURL.map(Self.applicationIdentity(for:))
        var orderedURLs = defaultURL.map { [$0] } ?? []
        orderedURLs.append(contentsOf: applicationURLs(fileURL).filter(shouldIncludeApplication))

        var seenIdentities: Set<String> = []
        return orderedURLs.compactMap { applicationURL in
            let identity = Self.applicationIdentity(for: applicationURL)
            guard seenIdentities.insert(identity).inserted else { return nil }
            return FileExternalOpenApplication(
                url: applicationURL,
                displayName: displayName(applicationURL),
                isDefault: identity == defaultIdentity
            )
        }
    }

    public static func applicationIdentity(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func liveDisplayName(for applicationURL: URL) -> String {
        let bundle = Bundle(url: applicationURL)
        let bundleName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
        var name = bundleName ?? FileManager.default.displayName(atPath: applicationURL.path)
        if name.lowercased().hasSuffix(".app") {
            name = String(name.dropLast(4))
        }
        return name.isEmpty ? applicationURL.deletingPathExtension().lastPathComponent : name
    }

    private static func shouldIncludeLiveApplication(_ applicationURL: URL) -> Bool {
        guard let bundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier?.lowercased() else {
            return true
        }
        if Bundle.main.bundleIdentifier?.lowercased() == bundleIdentifier {
            return false
        }
        return !bundleIdentifier.hasPrefix("dev.cmux.")
            && !bundleIdentifier.hasPrefix("com.cmuxterm.")
    }
}

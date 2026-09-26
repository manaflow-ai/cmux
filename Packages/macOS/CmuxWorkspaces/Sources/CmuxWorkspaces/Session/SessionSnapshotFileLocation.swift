public import Foundation

/// Where a cmux install keeps its session snapshot files.
///
/// Every install (stable, nightly, rc, staging, tagged debug builds) writes
/// `Application Support/cmux/session-<bundleId>.json` plus a
/// `session-<bundleId>-previous.json` manual-restore backup. Keying the file
/// on the bundle identifier keeps channels from clobbering each other; this
/// type lets one install locate another install's files so a session can be
/// moved between channels (`cmux restore-session --from nightly`).
public struct SessionSnapshotFileLocation: Sendable, Equatable {
    /// The stable channel's bundle identifier, also the fallback when the
    /// running bundle has none.
    public static let stableBundleIdentifier = "com.cmuxterm.app"

    /// Maps a release channel name to its bundle identifier.
    ///
    /// Accepts `stable` (alias `release`), `nightly`, `rc`, `staging`,
    /// `debug` (the untagged Debug build), and `debug:<tag>` / `dev:<tag>`
    /// for tagged Debug builds. The tag is normalized the way
    /// `scripts/reload.sh --tag` builds the bundle id (lowercased, every run
    /// of other characters becomes `.`), so `debug:My-Tag` is
    /// `com.cmuxterm.app.debug.my.tag`. A value that already is a cmux bundle
    /// identifier (`com.cmuxterm.app…`) is returned unchanged. Names are
    /// case-insensitive; returns nil for anything else.
    ///
    /// - Parameter name: The channel name or bundle identifier.
    /// - Returns: The bundle identifier, or nil when `name` is not a channel.
    public static func bundleIdentifier(forChannel name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == stableBundleIdentifier || trimmed.hasPrefix(stableBundleIdentifier + ".") {
            return trimmed
        }
        let lowered = trimmed.lowercased()
        switch lowered {
        case "stable", "release":
            return stableBundleIdentifier
        case "nightly", "rc", "staging", "debug":
            return "\(stableBundleIdentifier).\(lowered)"
        default:
            break
        }
        for prefix in ["debug:", "dev:"] where lowered.hasPrefix(prefix) {
            let tag = String(lowered.dropFirst(prefix.count))
                .replacingOccurrences(of: "[^a-z0-9]+", with: ".", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !tag.isEmpty else { return nil }
            return "\(stableBundleIdentifier).debug.\(tag)"
        }
        return nil
    }

    /// The user's Application Support directory the `cmux/` folder lives in.
    public let appSupportDirectory: URL

    /// Creates a location rooted at an Application Support directory.
    ///
    /// - Parameter appSupportDirectory: The user's Application Support
    ///   directory (tests pass a temporary directory).
    public init(appSupportDirectory: URL) {
        self.appSupportDirectory = appSupportDirectory
    }

    /// The primary snapshot file for `bundleIdentifier`.
    ///
    /// - Parameter bundleIdentifier: The install's bundle identifier; nil or
    ///   blank falls back to ``stableBundleIdentifier``.
    /// - Returns: `<appSupport>/cmux/session-<sanitized id>.json`.
    public func primaryFileURL(bundleIdentifier: String?) -> URL {
        fileURL(bundleIdentifier: bundleIdentifier, suffix: "")
    }

    /// The manual-restore backup snapshot file for `bundleIdentifier`.
    ///
    /// - Parameter bundleIdentifier: The install's bundle identifier; nil or
    ///   blank falls back to ``stableBundleIdentifier``.
    /// - Returns: `<appSupport>/cmux/session-<sanitized id>-previous.json`.
    public func backupFileURL(bundleIdentifier: String?) -> URL {
        fileURL(bundleIdentifier: bundleIdentifier, suffix: "-previous")
    }

    /// The side file that keeps a snapshot written by a newer schema version,
    /// next to the file it was found in (`session-<id>.json` becomes
    /// `session-<id>.schema-v<N>.json`).
    ///
    /// - Parameters:
    ///   - fileURL: The snapshot file that holds the newer snapshot.
    ///   - schemaVersion: The newer snapshot's schema version.
    /// - Returns: The side file location.
    public static func newerSchemaSideFileURL(for fileURL: URL, schemaVersion: Int) -> URL {
        let directory = fileURL.deletingLastPathComponent()
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        return directory.appendingPathComponent("\(baseName).schema-v\(schemaVersion).json", isDirectory: false)
    }

    func fileURL(bundleIdentifier: String?, suffix: String) -> URL {
        let trimmed = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bundleId = trimmed.isEmpty ? stableBundleIdentifier : bundleIdentifier!
        let safeBundleId = bundleId.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        return appSupportDirectory
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("session-\(safeBundleId)\(suffix).json", isDirectory: false)
    }
}

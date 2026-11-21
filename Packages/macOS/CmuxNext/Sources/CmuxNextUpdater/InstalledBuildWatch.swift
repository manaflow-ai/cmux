public import Foundation
import CmuxNextCompat

/// An update that is already installed on disk while the old build still runs: Sparkle (or a
/// download of the app by hand) swapped the bundle, but nobody relaunched, so the person runs a
/// days-old build without knowing (Leo's NIGHTLY, 2026-11-21: installed 75d22c95, running since
/// 11-16). The running app compares its own `CFBundleVersion` with the one in its bundle's
/// `Info.plist` on disk (``newerInstalledBuild(running:installed:)``); a newer one shows the
/// existing Restart to Update (``UpdaterService/installedBuild``). Pure and unit-tested.
nonisolated public struct InstalledBuildWatch {
    public nonisolated init() {}
    /// The build in the `Info.plist` of the bundle at `bundleURL` (`Contents/Info.plist`),
    /// nil when the bundle is gone or unreadable.
    public static func read(bundleURL: URL) -> InstalledBuild? {
        let plist = bundleURL.appending(path: "Contents/Info.plist")
        guard let data = try? Data(blockingContentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let build = info["CFBundleVersion"] as? String else { return nil }
        return InstalledBuild(build: build, shortVersion: info["CFBundleShortVersionString"] as? String)
    }

    /// The installed build when it is a newer build than the one `running`; nil when it is the
    /// same, older, unreadable or not comparable. A build that is not newer never offers a restart
    /// (an older bundle swapped in by a rollback is a person's own choice).
    public static func newerInstalledBuild(running: String, installed: InstalledBuild?) -> InstalledBuild? {
        guard let installed, isNewer(installed.build, than: running) else { return nil }
        return installed
    }

    /// Whether build `candidate` is newer than build `base`. Builds are dotted (`1.2.3`) or one
    /// plain number (`4487759453601`, which does not fit in every integer type, so digit runs are
    /// compared by length, then text). Equal, blank or non-comparable builds are not newer.
    public static func isNewer(_ candidate: String, than base: String) -> Bool {
        let new = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, !old.isEmpty, new != old else { return false }
        let newParts = parts(new), oldParts = parts(old)
        for index in 0..<max(newParts.count, oldParts.count) {
            let lhs = index < newParts.count ? newParts[index] : "0"
            let rhs = index < oldParts.count ? oldParts[index] : "0"
            if lhs == rhs { continue }
            return compare(lhs, rhs) == .orderedDescending
        }
        return false
    }

    private static func parts(_ build: String) -> [String] {
        build.split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "+" }).map(String.init)
    }

    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let digits = { (text: String) in !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber } }
        guard digits(lhs), digits(rhs) else { return lhs.compare(rhs, options: .numeric) }
        let a = String(lhs.drop { $0 == "0" }), b = String(rhs.drop { $0 == "0" })
        if a.count != b.count { return a.count > b.count ? .orderedDescending : .orderedAscending }
        return a.compare(b)
    }
}

/// The build a bundle on disk holds.
nonisolated public struct InstalledBuild: Equatable, Sendable {
    /// `CFBundleVersion`, which the comparison reads.
    public var build: String
    /// `CFBundleShortVersionString`, shown to people.
    public var shortVersion: String?

    public init(build: String, shortVersion: String?) {
        self.build = build
        self.shortVersion = shortVersion
    }

    /// "0.42.0 (1234)", the form the update card's detail reads (``UpdateChangelog``).
    public var displayVersion: String {
        shortVersion.map { "\($0) (\(build))" } ?? build
    }
}

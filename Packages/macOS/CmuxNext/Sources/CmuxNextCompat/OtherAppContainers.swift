public import Foundation

/// Other apps' sandbox and group containers (`~/Library/Containers`, `~/Library/Group Containers`), where
/// macOS guards each app's data: a look inside one (a `stat`, an `open`) from another app asks the person to
/// let it "access data from other apps", or blocks it with a "Data Access Blocked" notification. macOS
/// remembers the answer per app identity, so each `cmux app try` copy (a new bundle id and an ad hoc
/// signature) is asked again (Leo 2026-11-22, a copy's notification: "Data Access Blocked: "cmux
/// try-feat-agent-send-pop-f03f49" tried to access your data from other apps and was blocked." "weird stuff").
///
/// A side instance (`scripts/cmux-next/side-instance.sh`: `cmux app try`, try-pr, hot-verify) never looks in
/// one: its browser import and screenshot detection skip those paths. Every other build reads them as before.
/// The daemon's browser import refuses them in every build (cmux-browser-import `ops::PROTECTED`).
public nonisolated struct OtherAppContainers {
    public nonisolated init() {}
    /// Whether `url` is inside `~/Library/Containers` or `~/Library/Group Containers` (any home).
    public static func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.contains("/Library/Containers/") || path.contains("/Library/Group Containers/")
            || path.hasSuffix("/Library/Containers") || path.hasSuffix("/Library/Group Containers")
    }

    /// Whether the running app may look inside other apps' containers: not in a side instance.
    public static let mayRead: Bool = !isSideInstance(bundleID: Bundle.main.bundleIdentifier)

    /// Whether `url` may be looked at by this app: outside every container, or in a build that may read them.
    public static func mayLook(at url: URL, readsContainers: Bool = mayRead) -> Bool {
        readsContainers || !contains(url)
    }

    /// A side instance's bundle id: `<original>.side-<name>-<6 hex of its root>` (side-instance.sh `make`).
    public static func isSideInstance(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleID.split(separator: ".").dropFirst().contains { part in
            let hash = part.suffix(7)
            return part.hasPrefix("side-") && part.count > "side-".count + hash.count && hash.first == "-"
                && hash.dropFirst().allSatisfy { $0.isHexDigit && !$0.isUppercase }
        }
    }
}

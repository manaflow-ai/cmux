public import Foundation

/// The build and the Mac as plain text, for a bug report or a chat: Copy Version Info and Copy
/// Debug Info in the command palette, and Copy Logs' header. It holds no host name, serial or
/// user name: the hardware is ``HardwareClass``-coarse and a folder in the home folder is
/// written with `~`.
///
/// ```swift
/// NSPasteboard.general.setString(BuildInfoReport.current().versionText(), forType: .string)
/// ```
public nonisolated struct BuildInfoReport: Sendable, Equatable {
    /// `CFBundleShortVersionString`, `?` when the bundle has none.
    public var version: String
    /// `CFBundleVersion`, `?` when the bundle has none.
    public var build: String
    /// The bundle id, which names the channel (`com.cmuxterm.app.nightly`).
    public var bundleID: String
    /// `CMUXCommit`; nil in a build that has none.
    public var commit: String?
    /// The lines Copy Debug Info adds under the version lines (macOS, hardware, language, logs).
    public var system: [String]

    /// - Parameters:
    ///   - info: The bundle's Info.plist (`CFBundleShortVersionString`, `CFBundleVersion`, `CMUXCommit`).
    ///   - bundleID: The bundle id; `?` when nil.
    ///   - system: The lines Copy Debug Info adds under the version lines.
    public init(info: [String: Any], bundleID: String?, system: [String] = []) {
        func value(_ key: String) -> String? {
            (info[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        version = value("CFBundleShortVersionString") ?? "?"
        build = value("CFBundleVersion") ?? "?"
        self.bundleID = bundleID ?? "?"
        commit = value("CMUXCommit")
        self.system = system
    }

    /// This app's build (`Bundle.main`) and this Mac: macOS, the hardware class, the app's
    /// language and, when given, the log folder.
    public static func current(logs: URL? = nil) -> BuildInfoReport {
        let hardware = HardwareClass.current()
        var system = [
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Hardware: \(hardware.arch), \(hardware.chip), \(hardware.cores) cores, \(hardware.memoryGB) GB",
            "Language: \(Bundle.main.preferredLocalizations.first ?? "?") (system \(Locale.preferredLanguages.first ?? "?"))",
        ]
        if let logs { system.append("Logs: \(abbreviatingHome(logs.path, home: NSHomeDirectory()))") }
        return BuildInfoReport(info: Bundle.main.infoDictionary ?? [:], bundleID: Bundle.main.bundleIdentifier, system: system)
    }

    /// `cmux 0.65.2 (1234) com.cmuxterm.app.nightly`.
    public var headline: String { "cmux \(version) (\(build)) \(bundleID)" }

    /// Copy Version Info: the headline, then the commit when the build has one.
    public func versionText() -> String {
        var lines = [headline]
        if let commit { lines.append("Commit: \(commit)") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Copy Debug Info: the version text, then the system lines.
    public func debugText() -> String {
        versionText() + (system.isEmpty ? "" : system.joined(separator: "\n") + "\n")
    }

    /// Copy Logs' header: the headline, then the system lines.
    public var header: [String] { [headline] + system }

    /// `path` with the home folder written as `~`, so a pasted report names no user.
    public static func abbreviatingHome(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

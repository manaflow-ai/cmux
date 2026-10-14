import Foundation

/// A Muse Code executable cmux observed.
///
/// The user-facing `muse` launcher execs a versioned sibling binary such as
/// `muse-bin-1.4.6-R6000.1`. That binary is replaced on every update, so a
/// resume command must run the launcher, not the versioned binary it observed.
public struct MuseExecutableName: Sendable, Equatable {
    /// The launcher's executable name.
    public static let launcher = "muse"

    private static let versionedBinaryPrefix = "muse-bin-"

    /// The executable path or name as observed.
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    /// Whether this is a versioned Muse binary, including the truncated form
    /// macOS reports as a process name.
    public var isVersionedBinary: Bool {
        let base = URL(fileURLWithPath: value).lastPathComponent.lowercased()
        return base.hasPrefix(Self.versionedBinaryPrefix) && base.count > Self.versionedBinaryPrefix.count
    }

    /// The launcher to resume with.
    ///
    /// A versioned binary maps to the `muse` launcher in the same directory,
    /// where the launcher installs it; any other executable is kept.
    public var resumeExecutable: String {
        guard isVersionedBinary else { return value }
        guard value.contains("/") else { return Self.launcher }
        return URL(fileURLWithPath: value)
            .deletingLastPathComponent()
            .appendingPathComponent(Self.launcher, isDirectory: false)
            .path
    }
}

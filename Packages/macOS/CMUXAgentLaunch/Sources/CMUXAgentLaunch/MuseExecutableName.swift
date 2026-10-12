import Foundation

/// Names the Muse Code executables cmux observes.
///
/// The user-facing `muse` launcher execs a versioned sibling binary such as
/// `muse-bin-1.4.6-R6000.1`. That binary is replaced on every update, so a
/// resume command must run the launcher, not the versioned binary it observed.
public enum MuseExecutableName {
    /// The launcher's executable name.
    public static let launcher = "muse"

    private static let versionedBinaryPrefix = "muse-bin-"

    /// Whether `name` is a versioned Muse binary basename, including the
    /// truncated form macOS reports as a process name.
    public static func isVersionedBinary(_ name: String?) -> Bool {
        guard let name else { return false }
        let base = URL(fileURLWithPath: name).lastPathComponent.lowercased()
        return base.hasPrefix(versionedBinaryPrefix) && base.count > versionedBinaryPrefix.count
    }

    /// The launcher to resume with for a captured executable.
    ///
    /// A versioned binary maps to the `muse` launcher in the same directory,
    /// where the launcher installs it; any other executable is kept.
    public static func resumeExecutable(forCaptured executable: String) -> String {
        guard isVersionedBinary(executable) else { return executable }
        guard executable.contains("/") else { return launcher }
        return URL(fileURLWithPath: executable)
            .deletingLastPathComponent()
            .appendingPathComponent(launcher, isDirectory: false)
            .path
    }
}

public import Foundation

/// What the source detector reads from this Mac: preferences, a few small
/// settings files, folder existence and the home and temporary folders.
/// ``SystemScreenshotEnvironment`` reads the real ones; tests pass a fixture.
public nonisolated protocol ScreenshotEnvironment: Sendable {
    /// The person's home folder.
    var homeDirectory: URL { get }
    /// This process's temporary folder (`$TMPDIR`, shared by the person's unsandboxed apps).
    var temporaryDirectory: URL { get }

    /// A string preference, nil when unset or not a string.
    ///
    /// - Parameters:
    ///   - key: the preference key.
    ///   - domain: the preferences domain (`com.apple.screencapture`).
    func preference(_ key: String, domain: String) -> String?

    /// Every string preference of `domain` (the app's own and its sandbox container's).
    ///
    /// - Parameter domain: the preferences domain.
    func stringPreferences(domain: String) -> [String: String]

    /// A small text file's contents, nil when it is missing or unreadable.
    ///
    /// - Parameter url: the file.
    func text(at url: URL) -> String?

    /// Whether a folder (not a file) is at `url`.
    ///
    /// - Parameter url: the place.
    func isDirectory(_ url: URL) -> Bool
}

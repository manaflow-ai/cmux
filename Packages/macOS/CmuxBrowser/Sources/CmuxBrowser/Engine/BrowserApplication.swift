public import Foundation

/// An installed browser application that can host a Chromium engine process.
public struct BrowserApplication: Equatable, Sendable {
    /// The application's bundle identifier.
    public let bundleIdentifier: String

    /// The URL of the application bundle.
    public let bundleURL: URL

    /// The executable launched for Chrome DevTools Protocol control.
    public let executableURL: URL

    /// Creates an installed-browser description.
    ///
    /// - Parameters:
    ///   - bundleIdentifier: The application's bundle identifier.
    ///   - bundleURL: The application bundle URL.
    ///   - executableURL: The executable inside the application bundle.
    public init(bundleIdentifier: String, bundleURL: URL, executableURL: URL) {
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL
        self.executableURL = executableURL
    }
}

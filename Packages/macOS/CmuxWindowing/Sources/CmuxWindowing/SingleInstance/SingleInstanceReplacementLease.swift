public import Foundation

/// A short-lived, process-bound authorization for an intentional app relaunch.
///
/// The updater arms this lease before Sparkle relaunches cmux. A normal Dock or
/// LaunchServices open has no lease and therefore cannot replace a live process.
public struct SingleInstanceReplacementLease: Codable, Equatable, Sendable {
    public static let maxAge: TimeInterval = 30

    public let bundlePath: String
    public let processIdentifier: Int32
    public let issuedAt: TimeInterval

    public init(bundleURL: URL, processIdentifier: Int32, issuedAt: Date = Date()) {
        self.bundlePath = Self.canonical(bundleURL)
        self.processIdentifier = processIdentifier
        self.issuedAt = issuedAt.timeIntervalSince1970
    }

    public func authorizes(
        bundleURL: URL,
        processIdentifier: Int32,
        now: Date = Date()
    ) -> Bool {
        guard self.processIdentifier == processIdentifier,
              bundlePath == Self.canonical(bundleURL) else {
            return false
        }
        let age = now.timeIntervalSince1970 - issuedAt
        return age >= 0 && age <= Self.maxAge
    }

    private static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

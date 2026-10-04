public import Foundation

/// Fetches, verifies and caches signed release notes (R114 changelog).
/// Notes live next to the build's appcast: `<feed folder>/notes/<build>.json`
/// and `.sig`. Only notes whose signature verifies are cached or returned;
/// offline, the cache answers.
nonisolated public struct ReleaseNotesStore: Sendable {
    public let notesBase: URL
    public let cache: URL
    public let publicKey: String
    private let fetcher: any AppcastFetching

    /// - Parameter feedURL: the build's appcast URL; notes sit in its folder.
    public init?(feedURL: String, cache: URL, publicKey: String = ContentSignature.publicKey,
                 fetcher: any AppcastFetching = URLSessionAppcastFetcher()) {
        return nil
    }

    /// The verified notes of `build`: fresh when the network answers, else cached.
    @concurrent
    public func notes(for build: String) async -> ReleaseNotes? { nil }

    /// The verified index of recent builds (newest first), fresh or cached.
    @concurrent
    public func index() async -> [ReleaseNotesIndexEntry] { [] }
}

/// One build in `notes/index.json`.
nonisolated public struct ReleaseNotesIndexEntry: Codable, Equatable, Sendable {
    public var build: String
    public var shortVersion: String
    public var date: String
    public var highlights: Int
}

package import CryptoKit
public import Foundation

/// Fetches the pinned react-grab release once per run and checks its SHA-256 before handing it out.
///
/// The library is not bundled: like classic cmux, it comes from unpkg at a pinned version and is
/// refused unless its hash matches the pin. Concurrent callers share one download.
///
/// ```swift
/// let loader = ReactGrabScriptLoader()            // the shipped pin, URLSession
/// let test = ReactGrabScriptLoader(version: "9.9.9", sha256: hex) { _ in data }
/// ```
public actor ReactGrabScriptLoader: ReactGrabScriptSource {
    /// The react-grab release cmux loads.
    public static let pinnedVersion = "0.1.29"
    /// The SHA-256 (lowercase hex) of ``pinnedVersion``'s `dist/index.global.js`.
    public static let pinnedSHA256 = "4a1e71090e8ad8bb6049de80ccccdc0f5bb147b9f8fb88886d871612ac7ca04b"

    /// Where the library is downloaded from; nil when `version` makes no valid URL.
    public nonisolated let url: URL?
    private let sha256: String
    private let fetch: @Sendable (URL) async throws -> Data
    private var cached: String?
    private var inFlight: Task<String, any Error>?

    /// Creates a loader for one react-grab release.
    ///
    /// - Parameter version: The npm version to load; defaults to ``pinnedVersion``.
    /// - Parameter sha256: The expected lowercase hex SHA-256 of the file; defaults to ``pinnedSHA256``.
    /// - Parameter fetch: Downloads a URL's bytes; defaults to `URLSession.shared`. Tests pass a fake.
    public init(
        version: String = ReactGrabScriptLoader.pinnedVersion,
        sha256: String = ReactGrabScriptLoader.pinnedSHA256,
        fetch: @escaping @Sendable (URL) async throws -> Data = ReactGrabScriptLoader.download
    ) {
        // The version is a fixed npm semver from this file or a test, never user input.
        self.url = URL(string: "https://unpkg.com/react-grab@\(version)/dist/index.global.js")
        self.sha256 = sha256
        self.fetch = fetch
    }

    /// The library source, downloaded on first use and cached for the run.
    ///
    /// - Throws: ``ReactGrabError/integrityMismatch`` when the hash differs from the pin,
    ///   ``ReactGrabError/notText`` for a non-UTF-8 file, or the download's error.
    public func script() async throws -> String {
        if let cached { return cached }
        if let inFlight { return try await inFlight.value }
        guard let url else { throw ReactGrabError.badVersion }
        let task = Task { [sha256, fetch] in
            let data = try await fetch(url)
            let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard hex == sha256 else { throw ReactGrabError.integrityMismatch }
            guard let text = String(data: data, encoding: .utf8) else { throw ReactGrabError.notText }
            return text
        }
        inFlight = task
        defer { inFlight = nil }
        let text = try await task.value
        cached = text
        return text
    }

    /// The default `fetch`: the URL's bytes through `URLSession.shared` (a named function, not
    /// an async closure default argument; cx-bsue).
    public nonisolated static func download(_ url: URL) async throws -> Data {
        try await URLSession.shared.data(from: url).0
    }
}

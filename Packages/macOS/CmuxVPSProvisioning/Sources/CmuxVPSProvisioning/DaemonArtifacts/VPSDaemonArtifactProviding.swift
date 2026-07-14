/// Seam for acquiring a verified cmuxd-remote binary for a remote platform.
///
/// Production uses the embedded release manifest + shared download cache
/// (``VPSManifestArtifactProvider``); tests inject a fake.
public protocol VPSDaemonArtifactProviding: Sendable {
    /// Daemon version this provider installs.
    var version: String { get }

    /// The expected SHA-256 for the platform without downloading, or `nil`
    /// when unknown before ``materialize(goOS:goArch:)`` (dev override).
    ///
    /// - Parameters:
    ///   - goOS: Remote GOOS.
    ///   - goArch: Remote GOARCH.
    func expectedSHA256(goOS: String, goArch: String) -> String?

    /// Produces the verified local binary for the platform, downloading and
    /// checksum-verifying it when not already cached.
    ///
    /// - Parameters:
    ///   - goOS: Remote GOOS.
    ///   - goArch: Remote GOARCH.
    /// - Returns: The verified artifact.
    /// - Throws: ``VPSProvisioningError/artifactUnavailable(detail:)`` when
    ///   no verified binary can be produced.
    func materialize(goOS: String, goArch: String) async throws -> VPSDaemonArtifact
}

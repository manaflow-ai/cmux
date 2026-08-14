/// A manifest together with the provenance needed by diagnostics.
public struct CmuxAgentManifestEntry: Equatable, Hashable, Sendable {
    /// The validated manifest value.
    public let manifest: CmuxAgentDetectionManifest
    /// The source tier used for precedence.
    public let source: CmuxAgentManifestSource
    /// The absolute user-file path, or `nil` for bundled resources.
    public let sourcePath: String?

    /// Creates a manifest entry with optional source provenance.
    public init(
        manifest: CmuxAgentDetectionManifest,
        source: CmuxAgentManifestSource,
        sourcePath: String? = nil
    ) {
        self.manifest = manifest
        self.source = source
        self.sourcePath = sourcePath
    }
}

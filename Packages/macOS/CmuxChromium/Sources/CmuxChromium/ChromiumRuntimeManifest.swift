public import Foundation

/// Metadata describing a downloaded OWL Chromium runtime, decoded from
/// `owl-runtime-manifest.json` at the root of a runtime directory.
///
/// The manifest is written by the `manaflow-ai/chromium` release workflow and
/// records which source commit and CI run produced the artifact.
public struct ChromiumRuntimeManifest: Codable, Sendable, Equatable {
    /// Git URL of the Chromium source fork the runtime was built from.
    public let chromiumSourceRepo: String?
    /// Branch or ref of the source fork used for the build.
    public let chromiumSourceRef: String?
    /// Full commit hash of the source fork used for the build.
    public let chromiumSourceCommit: String?
    /// GitHub repository that published the runtime artifact.
    public let artifactRepo: String?
    /// Name of the workflow that produced the artifact.
    public let artifactWorkflow: String?
    /// Identifier of the workflow run that produced the artifact.
    public let artifactRunId: String?

    /// Decodes a manifest from raw JSON data.
    ///
    /// - Parameter data: Contents of an `owl-runtime-manifest.json` file.
    /// - Throws: `DecodingError` if the data is not valid manifest JSON.
    public init(data: Data) throws {
        self = try JSONDecoder().decode(ChromiumRuntimeManifest.self, from: data)
    }
}

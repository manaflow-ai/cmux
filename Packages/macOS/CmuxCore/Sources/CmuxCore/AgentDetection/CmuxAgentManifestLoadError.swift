public import Foundation

/// A failure to construct an accepted manifest catalog.
public enum CmuxAgentManifestLoadError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    /// The bundle did not contain any manifest resources.
    case noBundledManifests
    /// A manifest file failed decoding or validation.
    case invalidFile(path: String, reason: String)
    /// Two bundled resources declared the same agent id.
    case duplicateID(id: String, path: String)
    /// A user filename did not match its manifest id.
    case invalidOverrideFilename(path: String, id: String)
    /// A user file requested an unsupported merge strategy.
    case unsupportedMergeStrategy(path: String, value: String)

    /// A concise, actionable diagnostic string.
    public var description: String {
        switch self {
        case .noBundledManifests:
            return CmuxAgentManifestCodec.localizedReason(
                "agentManifest.error.noBundledManifests",
                defaultValue: "No bundled agent manifests were found"
            )
        case let .invalidFile(path, reason):
            guard !path.isEmpty else { return reason }
            return CmuxAgentManifestCodec.localizedReason(
                "agentManifest.error.invalidFile",
                defaultValue: "%1$@: %2$@",
                arguments: [path, reason]
            )
        case let .duplicateID(id, path):
            return CmuxAgentManifestCodec.localizedReason(
                "agentManifest.error.duplicateID",
                defaultValue: "%1$@: duplicate agent id '%2$@'",
                arguments: [path, id]
            )
        case let .invalidOverrideFilename(path, id):
            return CmuxAgentManifestCodec.localizedReason(
                "agentManifest.error.invalidOverrideFilename",
                defaultValue: "%1$@: filename must be %2$@.json",
                arguments: [path, id]
            )
        case let .unsupportedMergeStrategy(path, value):
            return CmuxAgentManifestCodec.localizedReason(
                "agentManifest.error.unsupportedMergeStrategy",
                defaultValue: "%1$@: unsupported mergeStrategy '%2$@'",
                arguments: [path, value]
            )
        }
    }

    /// Localized-error bridge used by CLI and logging call sites.
    public var errorDescription: String? { description }
}

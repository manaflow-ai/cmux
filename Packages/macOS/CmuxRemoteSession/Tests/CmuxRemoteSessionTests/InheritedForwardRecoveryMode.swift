enum InheritedForwardRecoveryMode: Equatable, Sendable {
    case success
    case metadataMismatch
    case exitFailure
    case transientMetadataFailure
}

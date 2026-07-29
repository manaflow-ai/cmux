enum InheritedForwardRecoveryMode: Equatable, Sendable {
    case success
    case metadataMismatch
    case cancellationFailure
    case transientMetadataFailure
}

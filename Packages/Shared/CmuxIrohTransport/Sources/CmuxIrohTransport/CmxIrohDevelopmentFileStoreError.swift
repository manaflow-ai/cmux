/// Failure from the DEBUG-only file persistence used by ad-hoc app builds.
public enum CmxIrohDevelopmentFileStoreError: Error, Equatable, Sendable {
    /// The opaque repository scope is not safe to use as one path component.
    case invalidAccount

    /// The record exceeds the defensive per-record development limit.
    case recordTooLarge

    /// The sandboxed file operation failed.
    case storageFailure
}

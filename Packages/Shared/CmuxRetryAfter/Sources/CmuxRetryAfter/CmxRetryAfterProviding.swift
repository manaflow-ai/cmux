/// A transport-neutral server directive that forbids another request until a
/// validated delay has elapsed.
public protocol CmxRetryAfterProviding: Error, Sendable {
    var retryAfterSeconds: Int? { get }
}

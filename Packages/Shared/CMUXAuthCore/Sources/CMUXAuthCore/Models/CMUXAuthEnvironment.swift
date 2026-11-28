import Foundation

/// Which Stack Auth project an app build talks to.
///
/// Decided by the composition root (development for DEBUG builds, production
/// otherwise) and injected; this package never reads build flags itself.
public enum CMUXAuthEnvironment: Sendable {
    /// The development Stack project (DEBUG builds, local web stack).
    case development
    /// The production Stack project (Release/nightly builds).
    case production
}

/// The bounded origin of an Iroh connection close.
///
/// Raw values are stable diagnostic payload vocabulary. Append new cases;
/// never renumber an existing case.
public enum CmxIrohConnectionCloseInitiator: Int, Sendable, Equatable {
    /// The cause did not contain a recognized ownership token.
    case unknown = 0
    /// The local endpoint initiated the close.
    case local = 1
    /// The peer or remote endpoint initiated the close.
    case remote = 2
    /// The transport closed after a timeout.
    case timedOut = 3
}

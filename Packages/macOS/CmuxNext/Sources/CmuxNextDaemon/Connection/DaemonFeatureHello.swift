import CmuxNextCompat

/// The app's daemon features (process `daemon` or `both`) that its main connection sends in every
/// `client-hello`, and the daemon's last answer (p12-perf-process-150). The daemon outlives the app: it
/// turns off a verified app's `daemon` kill switch at once and keeps its own value for every other
/// difference until it restarts, which it reports as pending. `features.list` shows the last answer.
/// One instance per app launch, shared by every connection to the local daemon.
public final class DaemonFeatureHello: Sendable {
    /// The `features` member of `client-hello` step 1.
    public let request: ClientHelloRequest.Features
    private let reply = Mutex<ClientHelloRequest.FeatureReport?>(nil)

    /// `hash` is `FeatureList.daemonValuesHash` of `values` in registry order.
    public init(hash: String, values: [String: Bool]) {
        request = ClientHelloRequest.Features(hash: hash, values: values)
    }

    /// The daemon's answer to the last hello that carried the features; nil before one, or from a daemon
    /// that does not reconcile them (an older build).
    public var lastReply: ClientHelloRequest.FeatureReport? { reply.withLock { $0 } }

    /// Records the answer of a new connection's hello (nil from an older daemon).
    func record(_ report: ClientHelloRequest.FeatureReport?) {
        reply.withLock { $0 = report }
    }
}

import CmuxNextCompat

/// The app's daemon features (process `daemon` or `both`) that its main connection sends in every
/// `client-hello`, and the daemon's answer. The daemon outlives the app: it
/// turns off a verified app's `daemon` kill switch at once and keeps its own value for every other
/// difference until it restarts, which it reports as pending. The app then runs each pending feature
/// with the daemon's value too (``sessionValues``), so a `both` feature has one value in both processes
/// for the session, as a Chromium child process takes the browser's feature state instead of resolving
/// its own (`FeatureList::InitFromSharedMemory`, base/feature_list.cc). `features.list` shows the answer.
/// One instance per app launch, shared by every connection to the local daemon.
public final class DaemonFeatureHello: Sendable {
    /// The `features` member of `client-hello` step 1.
    public let request: ClientHelloRequest.Features
    private let state = Mutex(State())

    private typealias Waiter = @Sendable ([String: Bool]) -> Void

    private struct State {
        var reply: ClientHelloRequest.FeatureReport?
        var session: [String: Bool]?
        var waiters: [Waiter] = []
    }

    /// `hash` is `FeatureList.daemonValuesHash` of `values` in registry order.
    public init(hash: String, values: [String: Bool]) {
        request = ClientHelloRequest.Features(hash: hash, values: values)
    }

    /// The daemon's answer to the last hello that carried the features; nil before one, or from a daemon
    /// that does not reconcile them (an older build).
    public var lastReply: ClientHelloRequest.FeatureReport? { state.withLock { $0.reply } }

    /// The values this launch runs its daemon features with, fixed once by ``settle()``: the daemon's value
    /// for each feature its answer reported pending, the app's own for the rest (all of them with no answer).
    /// Nil before. An app reader of a `both` feature reads it here, never the app's launch value.
    public var sessionValues: [String: Bool]? { state.withLock { $0.session } }

    /// Calls `body` once with `name`'s session value (``sessionValues``, or `launchValue` for a feature the
    /// hello does not carry): now when ``settle()`` ran, else on the thread that runs it. `body` hops to
    /// its own thread.
    public func whenSessionValueKnown(of name: String, launchValue: Bool, _ body: @escaping @Sendable (Bool) -> Void) {
        let known: [String: Bool]? = state.withLock { state in
            if state.session == nil { state.waiters.append { body($0[name] ?? launchValue) } }
            return state.session
        }
        if let known { body(known[name] ?? launchValue) }
    }

    /// Records the answer of a new connection's hello (nil from an older daemon).
    func record(_ report: ClientHelloRequest.FeatureReport?) {
        state.withLock { $0.reply = report }
    }

    /// Fixes ``sessionValues`` from the last answer, once: when the app attaches its first connection (whose
    /// hello was the last one answered), or when the first connect gives up (no answer: the app's values).
    /// Later calls change nothing.
    public func settle() {
        let settled: (values: [String: Bool], waiters: [Waiter])? = state.withLock { state in
            guard state.session == nil else { return nil }
            let values = Self.sessionValues(app: request.values, report: state.reply)
            state.session = values
            let waiters = state.waiters
            state.waiters = []
            return (values, waiters)
        }
        guard let settled else { return }
        for waiter in settled.waiters { waiter(settled.values) }
    }

    /// The app's `values` with the daemon's value for each feature the daemon kept another value of.
    static func sessionValues(app values: [String: Bool], report: ClientHelloRequest.FeatureReport?) -> [String: Bool] {
        var session: [String: Bool] = values
        for pending in report?.pending ?? [] where session[pending.name] != nil {
            session[pending.name] = pending.daemon
        }
        return session
    }
}

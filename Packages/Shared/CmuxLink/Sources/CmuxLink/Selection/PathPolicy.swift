/// Which paths win (a3-link.md section 6). Default: direct > p2p > turn > relay.
public struct PathPolicy: Sendable, Hashable {
    public var order: [PathKind]
    /// After a success, how long to wait for a pending carrier that could
    /// produce a better path.
    public var preferenceWindow: Duration
    /// While connected below the best rank, retry better carriers after this
    /// one-shot delay (and on every network change). `nil` disables.
    public var upgradeRetry: Duration?

    public init(
        order: [PathKind] = [.direct, .p2p, .turn, .relay],
        preferenceWindow: Duration = .milliseconds(150),
        upgradeRetry: Duration? = .seconds(30)
    ) {
        self.order = order
        self.preferenceWindow = preferenceWindow
        self.upgradeRetry = upgradeRetry
    }

    /// Lower is better. Kinds missing from `order` rank last.
    public func rank(of kind: PathKind) -> Int {
        order.firstIndex(of: kind) ?? order.count
    }

    /// The best rank a carrier could produce.
    public func bestRank(of carrier: any LinkCarrier) -> Int {
        carrier.candidatePaths.map(rank(of:)).min() ?? order.count
    }
}

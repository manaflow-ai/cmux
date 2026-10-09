/// The pure transition function of `LinkState`. `LinkSession` is its only
/// writer; invalid transitions are ignored and reported as `false`.
public struct LinkStateMachine: Sendable, Hashable {
    public private(set) var state: LinkState

    public init(state: LinkState = .idle) {
        self.state = state
    }

    /// Applies `event`; returns whether the state changed.
    @discardableResult
    public mutating func apply(_ event: LinkStateEvent) -> Bool {
        guard let next = transition(from: state, on: event), next != state else { return false }
        state = next
        return true
    }

    private func transition(from state: LinkState, on event: LinkStateEvent) -> LinkState? {
        switch (state, event) {
        case (.closed, _):
            return nil
        case let (_, .close(reason)):
            return .closed(reason)
        case let (.idle, .attemptStarted(n)), let (.connecting, .attemptStarted(n)):
            return .connecting(attempt: n)
        case let (.reconnecting(_, last), .attemptStarted(n)):
            return .reconnecting(attempt: n, lastPath: last)
        case let (.idle, .connected(path)), let (.connecting, .connected(path)),
             let (.reconnecting, .connected(path)):
            return .connected(path)
        case let (.connected, .pathChanged(path)), let (.connected, .connected(path)):
            return .connected(path)
        case let (.degraded(_, reason), .pathChanged(path)):
            return .degraded(path, reason)
        case let (.degraded, .connected(path)):
            return .connected(path)
        case let (.connected(path), .health(.degraded(reason))),
             let (.degraded(path, _), .health(.degraded(reason))):
            return .degraded(path, reason)
        case let (.degraded(path, _), .health(.good)):
            return .connected(path)
        case let (.connected(path), .transportLost(n)), let (.degraded(path, _), .transportLost(n)):
            return .reconnecting(attempt: n, lastPath: path)
        default:
            return nil
        }
    }
}

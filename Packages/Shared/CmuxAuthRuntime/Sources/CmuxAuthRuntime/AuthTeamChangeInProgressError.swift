/// A team mutation was refused because another team mutation is still in flight.
public struct AuthTeamChangeInProgressError: Error, Equatable, Sendable {
    public init() {}
}

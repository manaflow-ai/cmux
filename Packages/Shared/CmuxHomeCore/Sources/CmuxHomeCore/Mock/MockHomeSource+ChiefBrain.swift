/// The mock owner's Hosted Chief brain, for previews, the gallery and tests.
extension MockHomeSource: HomeChiefBrainControlling {
    /// The id the mock's Hosted Chief brain answers for.
    public static let hostedChiefAgent = "agent_000000000000000000000000HC"

    /// Gives the mock a Hosted Chief brain that is on or off (nil: none);
    /// the next `failingTurnOns` Turn Ons fail.
    public func setHostedChiefBrain(enabled: Bool?, failingTurnOns: Int = 0) {
        hostedChiefBrain = enabled
        failingChiefTurnOns = failingTurnOns
    }

    public func chiefBrain() async throws -> HomeChiefBrainReading? {
        hostedChiefBrain.map { HomeChiefBrainReading(chief: Self.hostedChiefAgent, enabled: $0) }
    }

    public func setChiefBrain(_ chief: String, enabled: Bool) async throws {
        guard chief == Self.hostedChiefAgent, hostedChiefBrain != nil else { throw HomeRejection.invalid("chief.invalid") }
        if failingChiefTurnOns > 0 {
            failingChiefTurnOns -= 1
            throw HomeRejection.ownerUnreachable
        }
        hostedChiefBrain = enabled
    }
}

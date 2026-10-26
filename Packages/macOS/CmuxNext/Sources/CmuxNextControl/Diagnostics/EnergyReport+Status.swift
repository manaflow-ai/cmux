public import CmuxNextWakeups

extension EnergyReport {
    /// The status method's name; the daemon's own line has the same name on its session socket.
    public static let statusMethodName = "energy.status"

    /// `energy.status`, served in every build (`debug.energy` is Debug and bench only): `{policy, inputs}`,
    /// the same two keys `debug.energy` reports, for `cmux energy status` and the MCP `energy_status` tool.
    /// One main-actor turn copies them; nothing is sampled. `.null` once the services are gone.
    ///
    /// - Parameter read: The resolved policy and the inputs it was resolved from, now.
    public static func statusMethod(_ read: @escaping @MainActor @Sendable () -> (policy: EnergyPolicy, inputs: Inputs)?) -> ControlMethod {
        .mainActor(statusMethodName) { _ in
            guard let current = read() else { return .value(.null) }
            return .value(status(policy: current.policy, inputs: current.inputs))
        }
    }

    static func status(policy: EnergyPolicy, inputs: Inputs) -> JSONValue {
        ["policy": policyJSON(policy), "inputs": inputs.json(policy: policy)]
    }

    static func policyJSON(_ policy: EnergyPolicy) -> JSONValue {
        [
            "isSaver": .bool(policy.isSaver),
            "reason": policy.reason.map { EnergyReport.JSONValue.string($0.rawValue) } ?? .null,
            "wakeAlignmentMs": EnergyReport.ms(policy.wakeAlignment),
            "ambientMaxFPS": policy.ambientMaxFPS.map { EnergyReport.JSONValue($0) } ?? .null,
            "webFrameRate": policy.webFrameRate.map { EnergyReport.JSONValue($0) } ?? .null,
            "pollStretch": EnergyReport.JSONValue(policy.pollStretch),
            "pageSaver": .bool(policy.pageSaver),
        ]
    }
}

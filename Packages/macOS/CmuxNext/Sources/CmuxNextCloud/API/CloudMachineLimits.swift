/// The account's machine cap, from `GET /api/vm`'s `limits`. The server
/// resolves it from the plan's entitlements; the app never infers a cap from
/// the machines it lists (#16012).
public struct CloudMachineLimits: Sendable, Hashable, Decodable {
    /// Most machines that may run at once. Nil: no cap. Zero: machines are
    /// closed on this plan (a zero is never "no cap").
    public var maxActiveVms: Int?
    /// Machines running or starting now, as the server counts them.
    public var activeVmCount: Int

    public init(maxActiveVms: Int?, activeVmCount: Int) {
        self.maxActiveVms = maxActiveVms
        self.activeVmCount = activeVmCount
    }

    enum CodingKeys: String, CodingKey { case maxActiveVms, activeVmCount }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxActiveVms = try c.decodeIfPresent(Int.self, forKey: .maxActiveVms)
        activeVmCount = try c.decodeIfPresent(Int.self, forKey: .activeVmCount) ?? 0
    }
}

/// `GET /api/vm`'s body. A `limits` this client cannot read drops the cap,
/// never the machine list.
struct CloudMachineList: Decodable {
    var vms: [CloudMachine]
    var limits: CloudMachineLimits?

    enum CodingKeys: String, CodingKey { case vms, limits }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vms = try c.decode([CloudMachine].self, forKey: .vms)
        limits = (try? c.decodeIfPresent(CloudMachineLimits.self, forKey: .limits)) ?? nil
    }
}

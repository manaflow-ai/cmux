/// The account's machine cap, from `GET /api/vm`'s `limits`. The server
/// resolves it from the plan's entitlements; the app never infers a cap from
/// the machines it lists (#16012).
public struct CloudMachineLimits: Sendable, Hashable, Decodable {
    /// Most machines that may run at once. Nil: no cap. Zero: machines are
    /// closed on this plan (a zero is never "no cap").
    public var maxActiveVms: Int?
    /// Machines running or starting now, as the server counts them.
    public var activeVmCount: Int
    /// The plan that sets the cap (`free`, `go`, `pro`, `max`, `team`); nil when the server sent none.
    public var planId: String?

    /// Sizes the server permits this account to create, in MiB; absent on older servers.
    public var memoryOptionsMb: [Int]?
    /// Sizes the server offers only with a plan upgrade, in MiB.
    public var lockedMemoryOptionsMb: [Int]?

    public init(maxActiveVms: Int?, activeVmCount: Int, planId: String? = nil, memoryOptionsMb: [Int]? = nil, lockedMemoryOptionsMb: [Int]? = nil) {
        self.maxActiveVms = maxActiveVms
        self.activeVmCount = activeVmCount
        self.planId = planId
        self.memoryOptionsMb = memoryOptionsMb
        self.lockedMemoryOptionsMb = lockedMemoryOptionsMb
    }

    enum CodingKeys: String, CodingKey { case maxActiveVms, activeVmCount, planId, memoryOptionsMb, lockedMemoryOptionsMb }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxActiveVms = try c.decodeIfPresent(Int.self, forKey: .maxActiveVms)
        activeVmCount = try c.decodeIfPresent(Int.self, forKey: .activeVmCount) ?? 0
        planId = try? c.decodeIfPresent(String.self, forKey: .planId)
        memoryOptionsMb = try? c.decodeIfPresent([Int].self, forKey: .memoryOptionsMb)
        lockedMemoryOptionsMb = try? c.decodeIfPresent([Int].self, forKey: .lockedMemoryOptionsMb)
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

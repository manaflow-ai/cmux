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
    /// The memory sizes a create on this plan may ask for (`memoryOptionsMb`), smallest first;
    /// empty when the server sent none.
    public var memoryOptionsMb: [Int]
    /// The vCPUs the server gives each of those sizes (`vcpusByMemoryMb`), so a size is labeled
    /// without a table of the app's own.
    public var vcpusByMemoryMb: [Int: Int]
    /// Sizes the server offers only with a plan upgrade, in MiB; nil when the server sent none.
    public var lockedMemoryOptionsMb: [Int]?

    public init(maxActiveVms: Int?, activeVmCount: Int, planId: String? = nil,
                memoryOptionsMb: [Int] = [], vcpusByMemoryMb: [Int: Int] = [:], lockedMemoryOptionsMb: [Int]? = nil) {
        self.maxActiveVms = maxActiveVms
        self.activeVmCount = activeVmCount
        self.planId = planId
        self.memoryOptionsMb = memoryOptionsMb
        self.vcpusByMemoryMb = vcpusByMemoryMb
        self.lockedMemoryOptionsMb = lockedMemoryOptionsMb
    }

    enum CodingKeys: String, CodingKey { case maxActiveVms, activeVmCount, planId, memoryOptionsMb, vcpusByMemoryMb, lockedMemoryOptionsMb }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Each field on its own: one this client cannot read drops that field, never the others.
        // An unreadable cap reads as none, as a missing `limits` does (the server still refuses).
        maxActiveVms = (try? c.decodeIfPresent(Int.self, forKey: .maxActiveVms)) ?? nil
        activeVmCount = ((try? c.decodeIfPresent(Int.self, forKey: .activeVmCount)) ?? nil) ?? 0
        planId = try? c.decodeIfPresent(String.self, forKey: .planId)
        // Size fields this client cannot read leave the sizes out, never the cap.
        let options = ((try? c.decodeIfPresent([Int].self, forKey: .memoryOptionsMb)) ?? nil) ?? []
        memoryOptionsMb = Array(Set(options.filter { $0 > 0 })).sorted()
        let vcpus = ((try? c.decodeIfPresent([String: Int].self, forKey: .vcpusByMemoryMb)) ?? nil) ?? [:]
        vcpusByMemoryMb = Dictionary(vcpus.compactMap { key, value in Int(key).flatMap { $0 > 0 && value > 0 ? ($0, value) : nil } }) { first, _ in first }
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

public import CmuxNextDaemon

/// The Cloud size ladder a chat's machine is picked from (cmux-platform `Sizes.ts`) by ``planned(bytes:planMax:)``: the
/// size asked and every refusal keep ``floorDiskBytes(_:)`` (the folder plus what the machine keeps for itself,
/// ``reservedDiskBytes``); with the plan known, the size's disk grows toward ``neededDiskBytes(_:)`` (half again the
/// folder). `sm` is the platform's chat size: a create asks for a size only above it (``requested``), so
/// an older server is unaffected. cmux-tui's `link start-chat preflight` answers the same rules (`preflight.rs`).
public nonisolated enum CloudChatSize: String, CaseIterable, Comparable, Sendable {
    case sm, md, lg, xl
    case xxl = "2xl"

    /// What a machine's image and its own work keep of its disk (``CloudSeedRefusal``'s reserve too).
    public static let reservedDiskBytes: Int64 = 12 * 1_073_741_824

    /// The size's vCPUs.
    public var cpu: Int {
        switch self { case .sm: 2; case .md: 4; case .lg: 8; case .xl: 16; case .xxl: 32 }
    }
    /// The size's disk and memory, in MiB.
    public var diskMb: Int {
        switch self { case .sm: 16_384; case .md: 32_768; case .lg: 65_536; case .xl, .xxl: 131_072 }
    }
    public var memoryMb: Int {
        switch self { case .sm: 4_096; case .md: 8_192; case .lg: 16_384; case .xl: 32_768; case .xxl: 65_536 }
    }

    /// The ladder name a create sends: nil for the chat size (`sm`), which a server takes when the create names none.
    public var requested: String? { self == .sm ? nil : rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (allCases.firstIndex(of: lhs) ?? 0) < (allCases.firstIndex(of: rhs) ?? 0)
    }

    /// The size's own disk, in bytes.
    public var diskBytes: Int64 { Int64(diskMb) * 1_048_576 }

    /// The least disk that holds `bytes` of folder at all: the folder and the reserve. The rule every refusal keeps (a
    /// machine too small, a folder too big), as before the half-again target (cmux-tui `preflight::floor_disk`). Nil
    /// when it overflows.
    public static func floorDiskBytes(_ bytes: Int64) -> Int64? {
        let floor = max(bytes, 0).addingReportingOverflow(reservedDiskBytes)
        return floor.overflow ? nil : floor.partialValue
    }

    /// The disk a start grows its size toward for `bytes` of folder under a plan known: half again the folder, and at
    /// least its ``floorDiskBytes(_:)``. It only grows a disk (``grownDiskMb(_:bytes:planMax:)``): it never picks the
    /// size asked nor refuses (cmux-tui `preflight::needed_disk`). Nil when it overflows.
    public static func neededDiskBytes(_ bytes: Int64) -> Int64? {
        let bytes = max(bytes, 0)
        let halfAgain = bytes.addingReportingOverflow(bytes / 2 + bytes % 2)
        guard !halfAgain.overflow, let floor = floorDiskBytes(bytes) else { return nil }
        return max(halfAgain.partialValue, floor)
    }

    /// The smallest size (`sm` to `xl`; `2xl` has `xl`'s disk, so never the smallest) whose own disk holds the folder's
    /// ``floorDiskBytes(_:)``; nil above `xl` (cmux-tui `preflight::floor_index`).
    static func floorSize(bytes: Int64) -> Self? {
        guard let floor = floorDiskBytes(bytes) else { return nil }
        return [Self.sm, .md, .lg, .xl].first { floor <= $0.diskBytes }
    }

    /// The size a start with no plan known asks for `bytes` of folder: the smallest whose own disk holds the folder and
    /// the reserve, nil above `xl` (the rule before the half-again target; cmux-tui `preflight::needed_size`).
    public static func needed(bytes: Int64) -> Self? { planned(bytes: bytes, planMax: nil) }

    /// The most disk a Cloud machine has (cmux NEXT Max's largest): with a plan known, a folder whose
    /// ``floorDiskBytes(_:)`` is past it is too big.
    public static let maxDiskBytes: Int64 = 256 * 1_073_741_824

    /// The largest disk a plan whose largest size is `planMax` gives: `lg` (cmux NEXT Pro and the classic plans below
    /// Max) 128 GiB, `2xl` (Max) ``maxDiskBytes``, another size its own disk (cmux-tui `preflight::plan_disk`).
    public static func largestDiskBytes(planMax: Self) -> Int64 {
        switch planMax {
        case .lg: return Int64(128) * 1_073_741_824
        case .xxl: return maxDiskBytes
        case .sm, .md, .xl: return planMax.diskBytes
        }
    }

    /// The size a start asks for `bytes` of folder under a plan whose largest size is `planMax` (nil: not known,
    /// ``needed(bytes:)`` and no grown disk). With a plan known: ``needed(bytes:)`` when the plan gives it; else, when
    /// the plan's ``largestDiskBytes(planMax:)`` holds the floor, `planMax`, its disk grown
    /// (``grownDiskMb(_:bytes:planMax:)``; cmux-tui answers a server that ignores it with the plan's size refusal);
    /// else the size past the plan, which the server refuses with its upgrade (`cloud.size.locked`): ``needed(bytes:)``,
    /// or `2xl` above `xl`. Nil for a folder whose floor is past ``maxDiskBytes``. cmux-tui `preflight::planned_size`.
    public static func planned(bytes: Int64, planMax: Self?) -> Self? {
        let fit = floorSize(bytes: bytes)
        guard let planMax else { return fit }
        if let fit, fit <= planMax { return fit }
        guard let floor = floorDiskBytes(bytes), floor <= maxDiskBytes else { return nil }
        if floor <= largestDiskBytes(planMax: planMax) { return planMax }
        return fit ?? .xxl
    }

    /// The disk in MiB a create asks beyond `size`'s own for `bytes` of folder under a plan whose largest size is
    /// `planMax`: the ``neededDiskBytes(_:)`` rounded up to 4 GiB, at most the plan's ``largestDiskBytes(planMax:)``,
    /// only when that is more than the size's own disk; nil with no plan known (the start asks exactly what it did
    /// before the half-again target), no size, unknown bytes or a folder the size's own disk holds. cmux-tui
    /// `preflight::grown_disk_gib` (the ensure's `disk_gib`, in GiB).
    public static func grownDiskMb(_ size: Self?, bytes: Int64?, planMax: Self?) -> Int? {
        guard let size, let bytes, let planMax else { return nil }
        let needed = neededDiskBytes(bytes) ?? .max
        guard needed > size.diskBytes else { return nil }
        let gib: Int64 = 1_073_741_824, step: Int64 = 4
        let steps = needed / (step * gib) + (needed % (step * gib) == 0 ? 0 : 1)
        let grown = min(steps * step, largestDiskBytes(planMax: planMax) / gib)
        return grown * gib > size.diskBytes ? Int(grown) * 1_024 : nil
    }

    /// A GitHub repository's size from the repos list (`size_kb`, GitHub's KB): ``needed(bytes:)`` of it, `sm`
    /// when the list named none. A repository too big for any Cloud machine stays nil: the start says the folder is too big.
    public static func forRepository(sizeKb: Int?) -> Self? {
        guard let sizeKb else { return .sm }
        let bytes = Int64(max(sizeKb, 0)).multipliedReportingOverflow(by: 1024)
        return bytes.overflow ? nil : needed(bytes: bytes.partialValue)
    }
}

/// A create refused for its size on this plan (cmux-platform `admitSize`: `cloud.size.locked`, details `{needed, allowed,
/// upgrade_plan}`; the app server's `cmux.cloud.size_locked`), with what the start knows: the size it asked for and the
/// folder's bytes.
public nonisolated struct CloudSizeLocked: Error, Equatable, Sendable {
    /// The page's code for it.
    public static let pageCode = "cloud_size_locked"

    /// Whether `code` is this refusal: the platform's `cloud.size.locked`, or the app server's `cmux.cloud.size_locked`
    /// (by suffix, as cmux-cloud-start-core `machine_create` reads a definitive refusal).
    public static func isCode(_ code: String) -> Bool { code.hasSuffix("size.locked") || code.hasSuffix("size_locked") }

    /// The plans a refusal may name to lift it: cmux NEXT's own (`next_plus`, `next_pro`, `next_max`) and the classic
    /// ones a server may still send (`pro`, `max`).
    public static let plans = ["next_plus", "next_pro", "next_max", "pro", "max"]

    /// The plan that lifts it (one of ``plans``), nil when none does; ``upgradeNamed``: the server named one, or none.
    public var upgradePlan: String?
    public var upgradeNamed = false
    public var needed: CloudChatSize?
    /// The largest size the plan gives, as the server said.
    public var allowed: CloudChatSize?
    public var folderBytes: Int64?

    public init(upgradePlan: String? = nil, upgradeNamed: Bool = false, needed: CloudChatSize? = nil, allowed: CloudChatSize? = nil,
                folderBytes: Int64? = nil) {
        (self.upgradePlan, self.upgradeNamed, self.needed, self.allowed, self.folderBytes) = (upgradePlan, upgradeNamed, needed, allowed, folderBytes)
    }

    /// The refusal's `details` (the platform's, or cmux-tui's `size_locked` from a workspace machine's ensure):
    /// `needed`, `allowed` and `upgrade_plan` (null, or cmux-tui's `nothing`: no plan lifts it); an older platform's
    /// `memory_mb` stands in for the first. `plan` is the team's own plan, never the upgrade.
    public init(details: JSONValue?) {
        let size = { (key: String) in details?[key]?.stringValue.flatMap(CloudChatSize.init(rawValue:)) }
        let memory = details?["memory_mb"]?.doubleValue.flatMap { $0.isFinite && $0 > 0 && $0 < 1e9 ? Int($0) : nil }
        let upgrade = details?["upgrade_plan"]
        self.init(upgradePlan: upgrade?.stringValue.flatMap { Self.plans.contains($0) ? $0 : nil },
                  upgradeNamed: upgrade.map { $0 == .null || $0.stringValue != nil } ?? false,
                  needed: size("needed") ?? memory.flatMap { asked in CloudChatSize.allCases.first { $0.memoryMb >= asked } },
                  allowed: size("allowed"))
    }

    /// The refusal `error` is, or nil: this type, or an app op failure with its code (``isCode(_:)``).
    public static func of(_ error: any Error) -> Self? {
        if let locked = error as? Self { return locked }
        guard let failure = error as? CloudAppOpFailure, isCode(failure.code) else { return nil }
        return Self(details: failure.details)
    }

    /// The plan that lifts it: the server's, else the one whose machines reach ``needed`` (Pro: `lg`, 8 vCPU and 16 GB).
    public var upgrade: String? {
        if upgradeNamed { return upgradePlan }
        return needed.map { $0 <= .lg ? "pro" : "max" }
    }

    /// The largest size the plan gives: the server's (``allowed``), else the plan's own (`planMax`), else below
    /// ``needed``, as large as a Pro plan's when the upgrade is Max (classic or cmux NEXT); nil when nothing says.
    public func allowed(planMax: CloudChatSize?) -> CloudChatSize? {
        if let allowed { return allowed }
        if let planMax { return planMax }
        guard let needed, let below = CloudChatSize.allCases.last(where: { $0 < needed }) else { return nil }
        return upgrade == "max" || upgrade == "next_max" ? min(below, .lg) : below
    }

    /// `run`, its size refusal naming the start's `size` and folder `bytes` where the server's did not.
    @MainActor public static func naming<T>(_ size: CloudChatSize?, bytes: Int64?, _ run: @MainActor () async throws -> T) async throws -> T {
        do {
            return try await run()
        } catch {
            guard var locked = of(error) else { throw error }
            locked.needed = locked.needed ?? size
            locked.folderBytes = locked.folderBytes ?? bytes
            throw locked
        }
    }
}

public import CmuxNextDaemon

/// The Cloud size ladder a chat's machine is picked from (cmux-platform `Sizes.ts`): the smallest whose disk holds the
/// folder's ``neededDiskBytes(_:)``: half again what the chat's folder puts on it, and at least that plus what the
/// machine keeps for itself (``reservedDiskBytes``). `sm` is the platform's
/// chat size: a create asks for a size only above it (``requested``), so an older server is unaffected. cmux-tui's
/// `link start-chat preflight` answers the same rule for a folder (`needed_size`, `preflight.rs`).
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

    /// The disk a machine needs for `bytes` of folder: half again the folder, and at least the folder and the reserve
    /// (cmux-tui `preflight::needed_disk`). Nil when it overflows.
    public static func neededDiskBytes(_ bytes: Int64) -> Int64? {
        let bytes = max(bytes, 0)
        let halfAgain = bytes.addingReportingOverflow(bytes / 2 + bytes % 2)
        let reserved = bytes.addingReportingOverflow(reservedDiskBytes)
        guard !halfAgain.overflow, !reserved.overflow else { return nil }
        return max(halfAgain.partialValue, reserved.partialValue)
    }

    /// The most bytes of folder a `diskBytes` disk has room for under ``neededDiskBytes(_:)``: the disk less the
    /// reserve, and at most two thirds of it.
    public static func roomBytes(diskBytes: Int64) -> Int64 {
        let disk = max(diskBytes, 0)
        return min(disk - reservedDiskBytes, disk - (disk / 3 + (disk % 3 == 0 ? 0 : 1)))
    }

    /// The smallest chat size (`sm` to `xl`) whose disk holds the folder's ``neededDiskBytes(_:)``; nil above `xl`.
    public static func needed(bytes: Int64) -> Self? {
        guard let disk = neededDiskBytes(bytes) else { return nil }
        return [Self.sm, .md, .lg, .xl].first { disk <= Int64($0.diskMb) * 1_048_576 }
    }

    /// The most disk a Cloud machine has (cmux NEXT Max's largest).
    public static let maxDiskBytes: Int64 = 256 * 1_073_741_824

    /// The largest disk a plan gives, from its largest size: `lg` (cmux NEXT Pro and the classic plans below Max)
    /// 128 GiB, `2xl` (Max) ``maxDiskBytes``; nil for any other, a plan whose disk this does not know.
    public static func largestDiskBytes(planMax: Self) -> Int64? {
        switch planMax {
        case .lg: return Int64(128) * 1_073_741_824
        case .xxl: return maxDiskBytes
        case .sm, .md, .xl: return nil
        }
    }

    /// The size a start asks for `bytes` of folder whose ladder size is `natural` (``needed(bytes:)``, nil past `xl`),
    /// under a plan whose largest size is `planMax`; nil: too big for a Cloud machine. A folder past the plan's largest
    /// size whose ``neededDiskBytes(_:)`` the plan's largest disk holds asks that largest size, its disk grown
    /// (cmux-tui sends `disk_gib`); one past the plan's disk asks its own size (or `2xl`, up to ``maxDiskBytes``),
    /// which the plan refuses with its upgrade (`cloud.size.locked`). A plan not known (or a disk it does not know)
    /// keeps `natural`.
    public static func planned(_ natural: Self?, bytes: Int64, planMax: Self?) -> Self? {
        guard let planMax, let largest = largestDiskBytes(planMax: planMax) else { return natural }
        guard let disk = neededDiskBytes(bytes), disk <= maxDiskBytes else { return nil }
        if let natural, natural <= planMax { return natural }
        if disk <= largest { return planMax }
        return natural ?? .xxl
    }

    /// A GitHub repository's size from the repos list (`size_kb`, GitHub's KB): ``needed(bytes:)`` of it, `sm`
    /// when the list named none. A repository past `xl` stays nil: the start says the folder is too big.
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

    /// The plans a refusal may name to lift it: cmux NEXT's own (`next_pro`, `next_max`) and the classic ones a server
    /// may still send (`pro`, `max`).
    public static let plans = ["next_pro", "next_max", "pro", "max"]

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

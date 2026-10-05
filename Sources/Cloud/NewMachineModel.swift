import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import Observation

struct MachineSizeOption: Equatable, Sendable {
    let memoryMb: Int
    let diskMb: Int
    let vcpus: Int

    /// `servedVcpus` is the server's `limits.vcpusByMemoryMb` entry for this
    /// size. The table's vCPUs mirror `VM_IMAGE_SIZES`
    /// (web/services/vms/images/sizes.ts) only for a control plane that
    /// predates that field.
    init?(memoryMb: Int, servedVcpus: Int? = nil) {
        let vcpus = servedVcpus.flatMap { $0 > 0 ? $0 : nil }
        switch memoryMb {
        case 4096: self.init(memoryMb: memoryMb, diskMb: 16384, vcpus: vcpus ?? 2)
        case 8192: self.init(memoryMb: memoryMb, diskMb: 32768, vcpus: vcpus ?? 4)
        case 16384: self.init(memoryMb: memoryMb, diskMb: 65536, vcpus: vcpus ?? 8)
        case 24576: self.init(memoryMb: memoryMb, diskMb: 98304, vcpus: vcpus ?? 12)
        case 32768: self.init(memoryMb: memoryMb, diskMb: 131072, vcpus: vcpus ?? 16)
        case 65536: self.init(memoryMb: memoryMb, diskMb: 131072, vcpus: vcpus ?? 32)
        default: return nil
        }
    }

    private init(memoryMb: Int, diskMb: Int, vcpus: Int) {
        self.memoryMb = memoryMb
        self.diskMb = diskMb
        self.vcpus = vcpus
    }

    /// The localized RAM value shown as the selected picker title.
    var title: String {
        String(
            format: String(localized: "machines.new.size.option", defaultValue: "%d GB RAM"),
            memoryMb / 1024
        )
    }

    /// The localized disk value shown below the selected picker title.
    var detail: String {
        String(
            format: String(localized: "machines.new.size.detail", defaultValue: "%d GB disk included"),
            diskMb / 1024
        )
    }

    /// The localized disk value shown in the resource summary.
    var diskTitle: String {
        String(
            format: String(localized: "machines.new.size.gb", defaultValue: "%d GB"),
            diskMb / 1024
        )
    }

    /// The localized, compact row title shown in the size menu.
    var menuTitle: String {
        String(
            format: String(localized: "machines.new.size.menu.vcpu", defaultValue: "%1$d vCPU · %2$d GB RAM · %3$d GB disk"),
            vcpus,
            memoryMb / 1024,
            diskMb / 1024
        )
    }
}

/// State behind the New Machine sheet: what the person picked, what the plan
/// allows, and the one create call. The model never talks to the backend
/// itself and never waits for it: ``create()`` packs the choice into a
/// ``MachineCreateRequest``, hands it to the injected `submit` (the
/// ``MachineCreateCoordinator`` in the app), and finishes the sheet the
/// moment the CLI run is launched. The machine coming up is the
/// coordinator's business from then on; the Machines panel shows it.
@MainActor
@Observable
final class NewMachineModel {
    enum BaseImage: Hashable {
        case defaultImage
        case machine(VMSummary)

        var label: String {
            switch self {
            case .defaultImage:
                return String(localized: "machines.new.baseImage.default", defaultValue: "Default image")
            case .machine(let machine):
                return machine.displayName ?? machine.slug ?? machine.id
            }
        }

        static func == (lhs: BaseImage, rhs: BaseImage) -> Bool {
            switch (lhs, rhs) {
            case (.defaultImage, .defaultImage): return true
            case (.machine(let left), .machine(let right)): return left.id == right.id
            default: return false
            }
        }

        func hash(into hasher: inout Hasher) {
            switch self {
            case .defaultImage:
                hasher.combine(0)
            case .machine(let machine):
                hasher.combine(1)
                hasher.combine(machine.id)
            }
        }
    }
    /// Which create flow the sheet fronts.
    enum Mode: Equatable {
        /// `cmux vm new`: a fresh Freestyle machine with an ephemeral home.
        case newMachine
        /// `cmux vm base open --workspace <id>`: the persistent Base slot's
        /// first provisioning. Base has no size choice (the backend sizes it)
        /// and no name (it is always "Base").
        case base(workspaceID: UUID)
    }

    /// How the sheet ended.
    enum Outcome: Equatable {
        /// The create was launched and now runs in the background.
        case submitted
        case cancelled
    }

    /// Launches the create described by the request; returns false when it
    /// could not start (a sign-out raced the click), in which case the sheet
    /// stays up and says so.
    typealias Submit = @MainActor (MachineCreateRequest) -> Bool

    /// The base-image sizes the backend exposes, in ascending memory order.
    /// Each row is a validated Freestyle snapshot: 4/16, 8/32, 16/64,
    /// 24/96, 32/128, or 64/128 GB of memory/disk; the 64 GB row is Max only.
    /// The server's list trims this set for plan limits. Every machine draws
    /// its vCPUs and memory from the plan's shared pool. The 128 MiB BusyBox
    /// image is intentionally not a coding-machine option because it has no
    /// baked dev tools.
    nonisolated static let memoryOptionsMb: [Int] = [4096, 8192, 16384, 24576, 32768, 65536]
    static let planMachineMemoryMb = 8192
    /// The pre-ladder backend default. It is used only when the server omits
    /// `limits.memoryOptionsMb`, so the client does not send an unsupported
    /// `--size` flag during a rolling upgrade.
    static let legacyPlanMachineMemoryMb = 20480
    /// The plan that sells the ladder's 64 GB row and the larger pool
    /// (`MEMORY_UPGRADE_PLAN_ID` on the server).
    nonisolated static let maxPlanId = "max"
    /// The largest machine Pro, Team, and Founder's Edition may start
    /// (32 GB / 16 vCPU, the `xl` row).
    nonisolated static let standardPlanMaxMemoryMb = 32768
    /// The largest machine a free or unknown plan may start, where an operator
    /// opens free provisioning (`PLAN_MAX_MEMORY_MB` on the server).
    nonisolated static let freePlanMaxMemoryMb = 8192
    /// Mirrors `maxMemoryMbForPlan` without its env overrides: Max gets the
    /// whole ladder (64 GB), Pro, Team, and Founder's Edition stop at 32 GB,
    /// Go at 4 GB, and a free or unknown plan at 8 GB.
    /// The server's `limits.lockedMemoryOptionsMb` wins whenever it is sent;
    /// this mirror only covers a control plane that predates that field.
    nonisolated static func maxMemoryMb(planId: String?) -> Int {
        switch normalizedPlanId(planId) {
        case "go":
            return 4096
        case maxPlanId:
            return memoryOptionsMb.max() ?? standardPlanMaxMemoryMb
        case "pro", "team", "founders":
            return standardPlanMaxMemoryMb
        default:
            return freePlanMaxMemoryMb
        }
    }
    /// Mirrors `defaultMemoryMbForPlan`: the provider sizing profile, never above the max.
    static func defaultMemoryMb(planId: String?) -> Int {
        min(planMachineMemoryMb, maxMemoryMb(planId: planId))
    }
    /// Mirrors `lockedMemoryOptionsMbForPlan`: the ladder rows above the plan's ceiling.
    nonisolated static func mirroredLockedMemoryOptionsMb(planId: String?) -> [Int] {
        let ceiling = maxMemoryMb(planId: planId)
        return memoryOptionsMb.filter { $0 > ceiling }
    }
    nonisolated static func normalizedPlanId(_ planId: String?) -> String {
        (planId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    /// The plan name shown next to a locked size ("Requires Max").
    nonisolated static func planDisplayName(_ planId: String) -> String {
        switch normalizedPlanId(planId) {
        case maxPlanId:
            return String(localized: "machines.new.plan.name.max", defaultValue: "Max")
        case "pro":
            return String(localized: "machines.new.plan.name.pro", defaultValue: "Pro")
        default:
            return planId.trimmingCharacters(in: .whitespacesAndNewlines).capitalized
        }
    }

    let mode: Mode
    private(set) var plan: MachinePlanSnapshot?
    private(set) var sourceMachines: [VMSummary]
    var baseImage: BaseImage
    /// Sizes the plan may start, in ascending order: the server's
    /// `memoryOptionsMb` minus anything it (or the mirror) locks.
    private(set) var availableMemoryOptionsMb: [Int]
    /// Ladder sizes the plan cannot start; shown as disabled rows with the
    /// plan that unlocks them, never hidden.
    private(set) var lockedMemoryOptionsMb: [Int]
    /// The plan that sells the locked sizes; nil when nothing is locked.
    private(set) var memoryUpgradePlanId: String?
    private(set) var memoryUpgradePlansByMb: [String: String]?
    /// The server's vCPUs per size; nil from an older control plane.
    private(set) var vcpusByMemoryMb: [String: Int]?
    /// The server advertised a ladder, but every size is locked for this plan.
    /// Creation must stay disabled until the server returns an allowed size.
    private(set) var hasNoAllowedMemoryOptions = false
    /// Whether the authoritative plan read is still in flight.
    private(set) var planIsLoading: Bool
    /// A terminal plan-read failure keeps the sheet open so it can retry in place.
    private(set) var planLoadError: String?
    var onPlanRetry: (@MainActor () -> Void)?
    var selectedUpgradePlanId = "max"
    var showsMaxUpgrade = false
    private var storedMemoryMb: Int
    /// The selected size. A locked size never sticks: setting one snaps to
    /// the largest allowed size below it (or the smallest allowed size), so
    /// the create request can only carry a size the plan may start.
    var memoryMb: Int {
        get { storedMemoryMb }
        set { storedMemoryMb = Self.allowedMemoryMb(nearest: newValue, allowed: availableMemoryOptionsMb, locked: lockedMemoryOptionsMb) }
    }
    /// Why the create could not be launched; nil once a retry starts. Failures
    /// of the create itself never land here: by then the sheet is gone and the
    /// Machines panel row carries them.
    private(set) var errorText: String?
    private(set) var outcome: Outcome?

    /// Set by the presenter: called once when the sheet should close.
    var onFinished: (@MainActor (Outcome) -> Void)?

    /// Whether the control plane answered the network preset catalog. The
    /// Network section is editable only once it has: a server that does not
    /// know network policy would ignore it and give the machine full internet.
    enum NetworkAvailability: Equatable {
        case loading
        case available
        case unavailable
    }

    /// The outbound network choice for `vm new`. Base has no network choice.
    let network = CloudNetworkPolicyEditorModel()
    private(set) var networkAvailability: NetworkAvailability = .loading

    var supportsNetworkPolicy: Bool { mode == .newMachine }

    func applyNetworkCatalog(_ catalog: CloudNetworkPresetCatalog?) {
        guard let catalog else {
            networkAvailability = .unavailable
            return
        }
        network.setCatalog(catalog)
        networkAvailability = .available
    }

    /// The policy the create sends; nil keeps the server default. Only sent
    /// once the server proved it understands policies, and never when the
    /// person left it at the default (full internet, nothing listed).
    var requestedNetworkPolicy: CloudNetworkPolicy? {
        guard supportsNetworkPolicy, networkAvailability == .available, network.policy != .default else { return nil }
        return network.policy
    }

    /// "Keep coding agents up to date": the create sends `--agent-updates
    /// latest`. On by default; the sheet remembers a user who unchecks it.
    var keepsAgentsUpdated: Bool
    var supportsAgentUpdates: Bool { mode == .newMachine }

    /// Remembers the last submitted "Keep coding agents up to date" choice.
    nonisolated static let keepsAgentsUpdatedDefaultsKey = "cloud.newMachine.keepsAgentsUpdated"

    /// Shown under the toggle when the chosen network policy blocks a host
    /// the updates reach (the catalog's `agentUpdateDomains`). Only once the
    /// policy is editable, since until then the machine gets full internet.
    var agentUpdatesNetworkNote: String? {
        guard supportsAgentUpdates, keepsAgentsUpdated, networkAvailability == .available,
              let catalog = network.catalog else { return nil }
        return CloudAgentUpdates.latest.networkNote(for: network.policy, catalog: catalog)
    }

    private let submit: Submit
    private let selectionWindowID: UUID?
    private let defaults: UserDefaults

    func upgradePlan(for memoryMb: Int) -> String? {
        if let memoryUpgradePlansByMb { return memoryUpgradePlansByMb[String(memoryMb)] }
        guard memoryUpgradePlanId != nil else { return nil }
        if Self.normalizedPlanId(plan?.planId) == "go", memoryMb <= Self.standardPlanMaxMemoryMb { return "pro" }
        return Self.maxPlanId
    }

    func selectSize(_ memoryMb: Int) {
        if lockedMemoryOptionsMb.contains(memoryMb) {
            guard let target = upgradePlan(for: memoryMb) else { return }
            selectedUpgradePlanId = target
            showsMaxUpgrade = true
            PostHogAnalytics.shared.capture("cmux_vm_size_upgrade_prompted", properties: [
                "requested_memory_mb": memoryMb,
                "plan": plan?.planId ?? "unknown",
                "target_plan": target,
                "source": "mac_new_machine_sheet",
                "client": "mac"
            ])
            return
        }
        self.memoryMb = memoryMb
    }

    func applyPage(_ page: VMListPage) {
        applyPlan(activeCount: page.vms.count, limits: page.limits)
    }

    /// Replaces the plan in place (a background refresh of the cached plan).
    /// The selected size survives unless the new plan no longer allows it.
    func applyPlan(activeCount: Int, limits: VMPlanLimits?) {
        guard let limits else { return }
        let updated = NewMachineModel(
            mode: mode,
            plan: MachineSnapshotBuilder.planSnapshot(activeCount: activeCount, limits: limits),
            memoryOptionsMb: limits.memoryOptionsMb,
            lockedMemoryOptionsMb: limits.lockedMemoryOptionsMb,
            memoryUpgradePlanId: limits.memoryUpgradePlanId,
            memoryUpgradePlansByMb: limits.memoryUpgradePlansByMb,
            vcpusByMemoryMb: limits.vcpusByMemoryMb,
            sourceMachines: sourceMachines,
            baseImage: baseImage,
            selectionWindowID: selectionWindowID,
            defaults: defaults,
            submit: submit
        )
        guard planRefreshWouldChange(to: updated, storedMemoryMb: storedMemoryMb) else { return }
        plan = updated.plan
        availableMemoryOptionsMb = updated.availableMemoryOptionsMb
        lockedMemoryOptionsMb = updated.lockedMemoryOptionsMb
        memoryUpgradePlanId = updated.memoryUpgradePlanId
        memoryUpgradePlansByMb = updated.memoryUpgradePlansByMb
        vcpusByMemoryMb = updated.vcpusByMemoryMb
        hasNoAllowedMemoryOptions = updated.hasNoAllowedMemoryOptions
        planIsLoading = false
        planLoadError = nil
        if !availableMemoryOptionsMb.contains(storedMemoryMb) { storedMemoryMb = updated.memoryMb }
    }

    /// Records a failed authoritative read without dismissing the sheet.
    func setPlanLoadError(_ message: String) {
        planIsLoading = false
        planLoadError = message
    }
    /// Starts another authoritative plan read while keeping the sheet visible.
    func setPlanLoading() {
        planIsLoading = true
        planLoadError = nil
    }

    /// `memoryOptionsMb`, `lockedMemoryOptionsMb` and `memoryUpgradePlanId`
    /// are the server's `limits` fields. A nil `lockedMemoryOptionsMb` means
    /// the control plane predates the field, so the client mirror decides
    /// which ladder rows are locked; a nil upgrade plan with locked rows
    /// falls back to Max the same way.
    init(
        mode: Mode,
        plan: MachinePlanSnapshot?,
        memoryOptionsMb: [Int] = [],
        lockedMemoryOptionsMb: [Int]? = nil,
        memoryUpgradePlanId: String? = nil,
        memoryUpgradePlansByMb: [String: String]? = nil,
        vcpusByMemoryMb: [String: Int]? = nil,
        sourceMachines: [VMSummary] = [],
        baseImage: BaseImage = .defaultImage,
        selectionWindowID: UUID? = nil,
        defaults: UserDefaults = .standard,
        planIsLoading: Bool = false,
        submit: @escaping Submit
    ) {
        self.defaults = defaults
        self.keepsAgentsUpdated = defaults.object(forKey: Self.keepsAgentsUpdatedDefaultsKey) as? Bool ?? true
        self.memoryUpgradePlansByMb = memoryUpgradePlansByMb
        self.vcpusByMemoryMb = vcpusByMemoryMb
        self.mode = mode
        self.sourceMachines = sourceMachines.filter { !$0.id.isEmpty && $0.status != "destroyed" }
        self.baseImage = baseImage
        self.plan = plan
        self.planIsLoading = planIsLoading
        self.planLoadError = nil
        let serverOptions = Set(memoryOptionsMb.filter { MachineSizeOption(memoryMb: $0) != nil }).sorted()
        let locked: [Int]
        if serverOptions.isEmpty {
            // An empty list means an older control plane did not advertise the
            // ladder. Preserve its 20 GiB default and omit --size entirely; with
            // no size control there is nothing to lock either.
            locked = []
        } else if let lockedMemoryOptionsMb {
            locked = Set(lockedMemoryOptionsMb.filter { MachineSizeOption(memoryMb: $0) != nil }).sorted()
        } else {
            // Older control planes do not send lock metadata. Preserve the
            // compatibility ladder for those responses; newer responses use
            // the server's explicit locks above.
            locked = Self.mirroredLockedMemoryOptionsMb(planId: plan?.planId)
        }
        let allowed = serverOptions.filter { !locked.contains($0) }
        self.availableMemoryOptionsMb = allowed
        self.lockedMemoryOptionsMb = locked
        self.hasNoAllowedMemoryOptions = mode == .newMachine && !serverOptions.isEmpty && allowed.isEmpty
        if locked.isEmpty {
            self.memoryUpgradePlanId = nil
        } else if let memoryUpgradePlanId, !Self.normalizedPlanId(memoryUpgradePlanId).isEmpty {
            self.memoryUpgradePlanId = Self.normalizedPlanId(memoryUpgradePlanId)
        } else {
            self.memoryUpgradePlanId = Self.normalizedPlanId(plan?.planId) == Self.maxPlanId
                ? nil
                : Self.maxPlanId
        }
        self.submit = submit
        self.selectionWindowID = selectionWindowID
        self.storedMemoryMb = serverOptions.isEmpty
            ? Self.legacyPlanMachineMemoryMb
            : Self.defaultMemoryMb(planId: plan?.planId, options: allowed)
    }

    /// The size a selection lands on: `requested` itself unless the plan locks
    /// it, then the largest allowed size below it, then the smallest allowed.
    /// Off-ladder values pass through so the server can report them.
    nonisolated static func allowedMemoryMb(nearest requested: Int, allowed: [Int], locked: [Int]) -> Int {
        guard locked.contains(requested) else { return requested }
        if let below = allowed.filter({ $0 < requested }).max() { return below }
        return allowed.first ?? requested
    }

    /// The one machine cmux Cloud provisions: the devbox with the shell
    /// tooling, the coding agents and a VNC screen. One snapshot ladder serves
    /// every kind the backend knows, so the kind is not something the sheet
    /// asks about; the request carries it so the machine is recorded (and its
    /// Displays row shown) as what it is.
    static let machineKind: VMMachineKind = VMMachineKind.defaultKind

    /// `options` is the allowed list (already trimmed of locked sizes); the
    /// plan ceiling still applies for callers that pass the raw ladder.
    static func defaultMemoryMb(planId: String?, options: [Int] = memoryOptionsMb) -> Int {
        let allowed = options.filter { $0 <= maxMemoryMb(planId: planId) }.sorted()
        if allowed.contains(planMachineMemoryMb) { return planMachineMemoryMb }
        return allowed.first ?? planMachineMemoryMb
    }

    var isBaseSetup: Bool {
        if case .base = mode { return true }
        return false
    }

    /// Base is sized by the backend; only `vm new` takes `--size`.
    var supportsSize: Bool { mode == .newMachine && (planIsLoading || !availableMemoryOptionsMb.isEmpty) }
    var supportsBaseImage: Bool { mode == .newMachine }
    var isFork: Bool {
        if case .machine = baseImage { return true }
        return false
    }

    /// A cache refresh lands while the sheet is opening; reassigning an
    /// unchanged list would rebuild the Base pop-up mid-animation.
    func applySourceMachines(_ machines: [VMSummary]) {
        let filtered = machines.filter { !$0.id.isEmpty && $0.status != "destroyed" }
        let pickerRows: ([VMSummary]) -> [[String]] = { list in
            list.map { [$0.id, BaseImage.machine($0).label, $0.agentUpdates?.rawValue ?? ""] }
        }
        if pickerRows(filtered) != pickerRows(sourceMachines) {
            sourceMachines = filtered
        }
        if case .machine(let selected) = baseImage,
           !sourceMachines.contains(where: { $0.id == selected.id }) {
            baseImage = .defaultImage
        }
    }

    func selectBaseImage(_ image: BaseImage) {
        baseImage = image
        if case .machine(let machine) = image, let updates = machine.agentUpdates {
            keepsAgentsUpdated = updates == .latest
        }
    }
    /// Sizes the plan may start, ascending.
    var memoryOptions: [Int] { availableMemoryOptionsMb }
    /// Sizes the plan cannot start, ascending; the sheet lists them disabled.
    var lockedMemoryOptions: [Int] { lockedMemoryOptionsMb }

    var selectedSize: MachineSizeOption? { sizeOption(memoryMb: memoryMb) }

    /// A ladder size labeled with the server's vCPUs when it sent them.
    func sizeOption(memoryMb: Int) -> MachineSizeOption? {
        MachineSizeOption(memoryMb: memoryMb, servedVcpus: vcpusByMemoryMb?[String(memoryMb)])
    }

    /// "Max" for the plan that unlocks the locked sizes; nil when nothing is locked.
    var memoryUpgradePlanName: String? {
        memoryUpgradePlanId.map(Self.planDisplayName)
    }

    /// All plans represented by the locked rows, in ladder order.
    private var lockedMemoryUpgradePlanNames: String? {
        let planIDs = lockedMemoryOptions.compactMap { upgradePlan(for: $0) }
            .reduce(into: [String]()) { result, planID in
                if !result.contains(planID) { result.append(planID) }
            }
        guard !planIDs.isEmpty else { return nil }
        return ListFormatter.localizedString(byJoining: planIDs.map(Self.planDisplayName))
    }

    /// The highest plan represented by the locked rows, used by the summary
    /// action so a mixed Go ladder always offers the complete upgrade.
    var highestLockedMemoryUpgradePlanId: String? {
        lockedMemoryOptions.compactMap { upgradePlan(for: $0) }
            .max { lhs, rhs in (lhs == "max" ? 2 : 1) < (rhs == "max" ? 2 : 1) }
    }

    /// "32 GB RAM · 128 GB disk · Requires Max" for a locked row.
    func lockedSizeMenuTitle(_ size: MachineSizeOption) -> String {
        guard let target = upgradePlan(for: size.memoryMb) else { return size.menuTitle }
        let memoryUpgradePlanName = Self.planDisplayName(target)
        let format = String(localized: "machines.new.size.locked.row", defaultValue: "%1$@ · Requires %2$@")
        return String(format: format, size.menuTitle, memoryUpgradePlanName)
    }

    /// "16 GB, 24 GB, and 32 GB machines need cmux Max."; nil when nothing is locked
    /// or no plan sells the locked sizes.
    var lockedSizesNoteText: String? {
        guard supportsSize, !lockedMemoryOptions.isEmpty, let memoryUpgradePlanNames = lockedMemoryUpgradePlanNames else { return nil }
        let sizes = lockedMemoryOptions.compactMap { upgradePlan(for: $0) == nil ? nil : Self.memoryLabel(mb: $0) }
        let joined = ListFormatter.localizedString(byJoining: sizes)
        let format = String(localized: "machines.new.size.locked.note", defaultValue: "%1$@ machines need cmux %2$@.")
        return String(format: format, joined, memoryUpgradePlanNames)
    }

    /// "Upgrade to Max"; nil when nothing is locked.
    var memoryUpgradeButtonTitle: String? {
        guard lockedSizesNoteText != nil, let memoryUpgradePlanNames = lockedMemoryUpgradePlanNames else { return nil }
        let format = String(localized: "machines.new.size.locked.upgrade", defaultValue: "Upgrade to %@")
        return String(format: format, memoryUpgradePlanNames)
    }

    /// The sheet's plan usage, "0 of 1 machine in use"; nil when the plan is unknown.
    /// Uncapped plans read "2 machines in use".
    var planMeterText: String? {
        guard let plan else { return nil }
        guard let maxActiveVms = plan.maxActiveVms else {
            if plan.activeCount == 1 {
                return String(localized: "machines.new.plan.unlimited.single", defaultValue: "1 machine in use")
            }
            let format = String(localized: "machines.new.plan.unlimited", defaultValue: "%1$d machines in use")
            return String(format: format, plan.activeCount)
        }
        // The new machine counts toward the ceiling once it exists.
        let format = plan.isSingleMachinePlan
            ? String(localized: "machines.new.plan.single", defaultValue: "%1$d of 1 machine in use")
            : String(localized: "machines.new.plan.multi", defaultValue: "%1$d of %2$d machines in use")
        return String(format: format, plan.activeCount, maxActiveVms)
    }

    /// The shared pool's usage, "16 of 20 vCPUs · 32 of 40 GB RAM in use";
    /// nil for plans without a pool and control planes that predate it.
    var poolUsageText: String? {
        guard mode == .newMachine else { return nil }
        return plan?.resourcePool?.usageText
    }

    /// Why the selected size does not fit the pool's free vCPUs or memory
    /// right now; nil when it fits or the server sent no pool. The server
    /// enforces the pool, so this explains the refusal without blocking the
    /// create on a reading that may be a poll old.
    var selectedSizePoolShortfallText: String? {
        guard supportsSize, let pool = plan?.resourcePool, let size = selectedSize,
              let shortfall = pool.shortfall(vcpus: size.vcpus, memoryMb: size.memoryMb) else { return nil }
        return CloudVMResourcePool.shortfallText(
            shortfall,
            offersUpgrade: Self.normalizedPlanId(plan?.planId) != Self.maxPlanId
        )
    }

    /// The free plan's access window, so nobody is surprised a week later.
    var freeAccessNoteText: String? {
        guard let plan, !plan.isPaidPlan, plan.freeAccessWindowDays > 0 else { return nil }
        let format = String(
            localized: "machines.new.plan.freeWindow",
            defaultValue: "Free plan: this machine stays reachable for %d days. Upgrade to keep it."
        )
        return String(format: format, plan.freeAccessWindowDays)
    }

    static func memoryLabel(mb: Int) -> String {
        if mb % 1024 == 0 {
            let format = String(localized: "machines.new.size.gb", defaultValue: "%d GB")
            return String(format: format, mb / 1024)
        }
        let format = String(localized: "machines.new.size.mb", defaultValue: "%d MB")
        return String(format: format, mb)
    }

    /// The exact CLI invocation the create runs. Only the size is user input:
    /// the machine kind travels as ``machineKind``'s flag and the backend maps
    /// kind and size to the snapshot, so no name or image id leaves the sheet.
    /// `--focus false` is what makes the sheet's create a background one: the
    /// machine still opens (its own workspace, the Base placeholder) but the
    /// CLI never selects that workspace or moves keyboard focus out of the one
    /// the person is working in when it lands.
    var cliArguments: [String] {
        var arguments: [String]
        switch mode {
        case .newMachine:
            if case .machine(let machine) = baseImage {
                arguments = ["vm", "fork", machine.id]
            } else {
                arguments = ["vm", "new", Self.machineKind.cliFlag]
            }
            if isFork {
                arguments += ["--focus", "false"]
            } else {
            if supportsSize { arguments += ["--size", String(memoryMb)] }
            if let policy = requestedNetworkPolicy { arguments += ["--network-policy", policy.jsonString] }
            // Off sends nothing, so a server without the setting sees the old request.
            if keepsAgentsUpdated { arguments += ["--agent-updates", CloudAgentUpdates.latest.rawValue] }
            arguments += ["--focus", "false"]
            }
        case .base(let workspaceID):
            arguments = [
                "vm", "base", "open",
                "--workspace", workspaceID.uuidString,
                Self.machineKind.cliFlag,
                "--focus", "false",
            ]
        }
        if let selectionWindowID {
            arguments += ["--window", selectionWindowID.uuidString]
        }
        return arguments
    }

    /// The request the coordinator tracks for this sheet's choices.
    var createRequest: MachineCreateRequest {
        if case .newMachine = mode, case .machine(let machine) = baseImage {
            return .fork(
                sourceMachineID: machine.id,
                sourceName: baseImage.label,
                kind: Self.machineKind,
                selectionWindowID: selectionWindowID
            )
        }
        return MachineCreateRequest(
            mode: mode,
            kind: Self.machineKind,
            name: nil,
            arguments: cliArguments,
            selectionWindowID: selectionWindowID
        )
    }

    /// Launches the create and finishes the sheet. Nothing here waits on the
    /// machine: control returns to the person as soon as the CLI is running.
    func create() {
        guard outcome == nil, !hasNoAllowedMemoryOptions else { return }
        errorText = nil
        guard submit(createRequest) else {
            errorText = String(
                localized: "machines.new.error.launch",
                defaultValue: "cmux could not start the create command. Sign in and try again."
            )
            return
        }
        if supportsAgentUpdates { defaults.set(keepsAgentsUpdated, forKey: Self.keepsAgentsUpdatedDefaultsKey) }
        finish(.submitted)
    }

    func cancel() {
        guard outcome == nil else { return }
        finish(.cancelled)
    }

    private func finish(_ outcome: Outcome) {
        self.outcome = outcome
        onFinished?(outcome)
    }
}

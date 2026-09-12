import Foundation
import Observation

struct MachineSizeOption: Equatable, Sendable {
    let memoryMb: Int
    let diskMb: Int

    init?(memoryMb: Int) {
        switch memoryMb {
        case 4096: self.init(memoryMb: memoryMb, diskMb: 16384)
        case 8192: self.init(memoryMb: memoryMb, diskMb: 32768)
        case 16384: self.init(memoryMb: memoryMb, diskMb: 65536)
        case 24576: self.init(memoryMb: memoryMb, diskMb: 98304)
        case 32768: self.init(memoryMb: memoryMb, diskMb: 131072)
        case 65536: self.init(memoryMb: memoryMb, diskMb: 131072)
        default: return nil
        }
    }

    private init(memoryMb: Int, diskMb: Int) {
        self.memoryMb = memoryMb
        self.diskMb = diskMb
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
            format: String(localized: "machines.new.size.menu", defaultValue: "%1$d GB RAM · %2$d GB disk"),
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
    /// 24/96, 32/128, or 64/128 GB of memory/disk. The server's list trims
    /// this set for plan limits. The 128 MiB BusyBox image is intentionally
    /// not a coding-machine option because it has no baked dev tools.
    nonisolated static let memoryOptionsMb: [Int] = [4096, 8192, 16384, 24576, 32768, 65536]
    static let planMachineMemoryMb = 8192
    /// The pre-ladder backend default. It is used only when the server omits
    /// `limits.memoryOptionsMb`, so the client does not send an unsupported
    /// `--size` flag during a rolling upgrade.
    static let legacyPlanMachineMemoryMb = 20480
    /// The plan that sells the ladder's 32 GB and 64 GB rows
    /// (`MEMORY_UPGRADE_PLAN_ID` on the server).
    nonisolated static let maxPlanId = "max"
    /// The largest machine every plan except Max may start
    /// (`PLAN_MAX_MEMORY_MB` on the server).
    nonisolated static let standardPlanMaxMemoryMb = 24576
    /// Mirrors `maxMemoryMbForPlan` without its env overrides: Max gets the
    /// whole ladder, every other plan (and an unknown plan) stops at 24 GB.
    /// The server's `limits.lockedMemoryOptionsMb` wins whenever it is sent;
    /// this mirror only covers a control plane that predates that field.
    nonisolated static func maxMemoryMb(planId: String?) -> Int {
        if normalizedPlanId(planId) == maxPlanId {
            return memoryOptionsMb.max() ?? standardPlanMaxMemoryMb
        }
        return standardPlanMaxMemoryMb
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
    /// Sizes the plan may start, in ascending order: the server's
    /// `memoryOptionsMb` minus anything it (or the mirror) locks.
    private(set) var availableMemoryOptionsMb: [Int]
    /// Ladder sizes the plan cannot start; shown as disabled rows with the
    /// plan that unlocks them, never hidden.
    private(set) var lockedMemoryOptionsMb: [Int]
    /// The plan that sells the locked sizes; nil when nothing is locked.
    private(set) var memoryUpgradePlanId: String?
    var showsMaxUpgrade = false
    var refreshPlan: (@MainActor () async -> Void)?
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

    private let submit: Submit

    func selectSize(_ memoryMb: Int) {
        if lockedMemoryOptionsMb.contains(memoryMb) {
            guard memoryUpgradePlanId == Self.maxPlanId else { return }
            showsMaxUpgrade = true
            PostHogAnalytics.shared.capture("cmux_vm_size_upgrade_prompted", properties: [
                "requested_memory_mb": memoryMb,
                "plan": plan?.planId ?? "unknown",
                "target_plan": Self.maxPlanId,
                "source": "mac_new_machine_sheet",
                "client": "mac"
            ])
            return
        }
        self.memoryMb = memoryMb
    }

    func applyPage(_ page: VMListPage) {
        guard let limits = page.limits else { return }
        let updated = NewMachineModel(
            mode: mode,
            plan: MachineSnapshotBuilder.planSnapshot(activeCount: page.vms.count, limits: limits),
            memoryOptionsMb: limits.memoryOptionsMb,
            lockedMemoryOptionsMb: limits.lockedMemoryOptionsMb,
            memoryUpgradePlanId: limits.memoryUpgradePlanId,
            submit: submit
        )
        plan = updated.plan
        availableMemoryOptionsMb = updated.availableMemoryOptionsMb
        lockedMemoryOptionsMb = updated.lockedMemoryOptionsMb
        memoryUpgradePlanId = updated.memoryUpgradePlanId
        if !availableMemoryOptionsMb.contains(storedMemoryMb) { storedMemoryMb = updated.memoryMb }
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
        submit: @escaping Submit
    ) {
        self.mode = mode
        self.plan = plan
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
            locked = Self.mirroredLockedMemoryOptionsMb(planId: plan?.planId)
        }
        let allowed = serverOptions.filter { !locked.contains($0) }
        self.availableMemoryOptionsMb = allowed
        self.lockedMemoryOptionsMb = locked
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
    var supportsSize: Bool { mode == .newMachine && !availableMemoryOptionsMb.isEmpty }
    /// Sizes the plan may start, ascending.
    var memoryOptions: [Int] { availableMemoryOptionsMb }
    /// Sizes the plan cannot start, ascending; the sheet lists them disabled.
    var lockedMemoryOptions: [Int] { lockedMemoryOptionsMb }

    var selectedSize: MachineSizeOption? { MachineSizeOption(memoryMb: memoryMb) }

    /// "Max" for the plan that unlocks the locked sizes; nil when nothing is locked.
    var memoryUpgradePlanName: String? {
        memoryUpgradePlanId.map(Self.planDisplayName)
    }

    /// "32 GB RAM · 128 GB disk · Requires Max" for a locked row.
    func lockedSizeMenuTitle(_ size: MachineSizeOption) -> String {
        guard let memoryUpgradePlanName else { return size.menuTitle }
        let format = String(localized: "machines.new.size.locked.row", defaultValue: "%1$@ · Requires %2$@")
        return String(format: format, size.menuTitle, memoryUpgradePlanName)
    }

    /// "32 GB and 64 GB machines need cmux Max."; nil when nothing is locked
    /// or no plan sells the locked sizes.
    var lockedSizesNoteText: String? {
        guard supportsSize, !lockedMemoryOptions.isEmpty, let memoryUpgradePlanName else { return nil }
        let sizes = lockedMemoryOptions.map { Self.memoryLabel(mb: $0) }
        let joined = ListFormatter.localizedString(byJoining: sizes)
        let format = String(localized: "machines.new.size.locked.note", defaultValue: "%1$@ machines need cmux %2$@.")
        return String(format: format, joined, memoryUpgradePlanName)
    }

    /// "Upgrade to Max"; nil when nothing is locked.
    var memoryUpgradeButtonTitle: String? {
        guard lockedSizesNoteText != nil, let memoryUpgradePlanName else { return nil }
        let format = String(localized: "machines.new.size.locked.upgrade", defaultValue: "Upgrade to %@")
        return String(format: format, memoryUpgradePlanName)
    }

    /// "1 of 1 machine" from the panel's meter; nil when the plan is unknown.
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
        switch mode {
        case .newMachine:
            var arguments = ["vm", "new", Self.machineKind.cliFlag]
            if supportsSize { arguments += ["--size", String(memoryMb)] }
            arguments += ["--focus", "false"]
            return arguments
        case .base(let workspaceID):
            return [
                "vm", "base", "open",
                "--workspace", workspaceID.uuidString,
                Self.machineKind.cliFlag,
                "--focus", "false",
            ]
        }
    }

    /// The request the coordinator tracks for this sheet's choices.
    var createRequest: MachineCreateRequest {
        MachineCreateRequest(
            mode: mode,
            kind: Self.machineKind,
            name: nil,
            arguments: cliArguments
        )
    }

    /// Launches the create and finishes the sheet. Nothing here waits on the
    /// machine: control returns to the person as soon as the CLI is running.
    func create() {
        guard outcome == nil else { return }
        errorText = nil
        guard submit(createRequest) else {
            errorText = String(
                localized: "machines.new.error.launch",
                defaultValue: "cmux could not start the create command. Sign in and try again."
            )
            return
        }
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

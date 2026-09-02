import Foundation
import Observation

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
        /// `cmux vm new`: a fresh machine with its own persistent home.
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

    /// Memory sizes the backend accepts (`VM_MEMORY_OPTIONS_MB` in
    /// `web/services/vms/entitlements.ts`); the plan ceiling trims the tail.
    static let memoryOptionsMb: [Int] = [planMachineMemoryMb]
    /// The plan machine (`PLAN_MACHINE_MEMORY_MB`): 20 GB, 5 vCPU, 200 GB disk,
    /// the only size /pricing sells.
    static let planMachineMemoryMb = 20480
    /// Mirrors `maxMemoryMbForPlan`: the free machine is a full-size computer;
    /// paid plans unlock the largest size.
    static func maxMemoryMb(planId: String?) -> Int {
        _ = planId
        return planMachineMemoryMb
    }
    /// Mirrors `defaultMemoryMbForPlan`: the plan machine, never above the max.
    static func defaultMemoryMb(planId: String?) -> Int {
        min(planMachineMemoryMb, maxMemoryMb(planId: planId))
    }

    let mode: Mode
    let plan: MachinePlanSnapshot?
    let imageKinds: [VMImageKindOption]

    var name: String = ""
    /// Defaults to a kind the backend says it can actually serve (see
    /// ``defaultKind(imageKinds:)``), so the sheet never opens preselected on
    /// a kind whose create can only fail with an image config error.
    var kind: VMMachineKind
    var memoryMb: Int
    /// Why the create could not be launched; nil once a retry starts. Failures
    /// of the create itself never land here: by then the sheet is gone and the
    /// Machines panel row carries them.
    private(set) var errorText: String?
    private(set) var outcome: Outcome?

    /// Set by the presenter: called once when the sheet should close.
    var onFinished: (@MainActor (Outcome) -> Void)?

    private let submit: Submit

    init(
        mode: Mode,
        plan: MachinePlanSnapshot?,
        imageKinds: [VMImageKindOption],
        submit: @escaping Submit
    ) {
        self.mode = mode
        self.plan = plan
        self.imageKinds = imageKinds
        self.submit = submit
        self.memoryMb = Self.defaultMemoryMb(planId: plan?.planId)
        self.kind = Self.defaultKind(imageKinds: imageKinds)
    }

    /// Kinds the backend reports it can provision, in picker order.
    private static func servableKinds(imageKinds: [VMImageKindOption]) -> [VMMachineKind] {
        VMMachineKind.allCases.filter { kind in
            imageKinds.contains { $0.kind == kind }
        }
    }

    /// Kinds the sheet offers: what the backend reports it can provision, and
    /// every kind when it reports none (an older control plane that predates
    /// `limits.imageKinds`, where refusing to offer anything would be worse).
    static func selectableKinds(imageKinds: [VMImageKindOption]) -> [VMMachineKind] {
        let servable = servableKinds(imageKinds: imageKinds)
        return servable.isEmpty ? VMMachineKind.allCases : servable
    }

    /// The kind the sheet opens on: the first kind the backend can serve.
    /// When it reports none, shell-only: no provider ships a desktop image
    /// today, so preselecting Desktop would make the primary button fail with
    /// an image config error, while the picker still offers it.
    static func defaultKind(imageKinds: [VMImageKindOption]) -> VMMachineKind {
        servableKinds(imageKinds: imageKinds).first ?? .base
    }

    var selectableKinds: [VMMachineKind] { Self.selectableKinds(imageKinds: imageKinds) }

    var isBaseSetup: Bool {
        if case .base = mode { return true }
        return false
    }

    /// Base is sized by the backend; only `vm new` takes `--size`.
    var supportsSize: Bool { mode == .newMachine }
    var supportsName: Bool { mode == .newMachine }

    var memoryOptions: [Int] {
        let ceiling = Self.maxMemoryMb(planId: plan?.planId)
        return Self.memoryOptionsMb.filter { $0 <= ceiling }
    }

    /// The image the backend maps the chosen kind to, when it told us.
    var selectedImage: String? {
        imageKinds.first { $0.kind == kind }?.image
    }

    var trimmedName: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

    /// The exact CLI invocation the create runs. Kind travels as `--base` /
    /// `--desktop`; the backend maps it to an image, so no image id is pinned.
    /// `--focus false` is what makes the sheet's create a background one: the
    /// machine still opens (its own workspace, the Base placeholder) but the
    /// CLI never selects that workspace or moves keyboard focus out of the
    /// one the person is working in when it lands.
    var cliArguments: [String] {
        switch mode {
        case .newMachine:
            var arguments = ["vm", "new", kind == .desktop ? "--desktop" : "--base"]
            // `--size` travels only for a non-default pick: an omitted size lets
            // the backend apply its plan default, which an operator memory brake
            // (`CMUX_VM_*_MAX_MEMORY_MB`) may have clamped below the plan machine.
            if supportsSize, memoryMb != Self.defaultMemoryMb(planId: plan?.planId) {
                arguments += ["--size", String(memoryMb)]
            }
            if let trimmedName {
                arguments += ["--name", trimmedName]
            }
            arguments += ["--focus", "false"]
            return arguments
        case .base(let workspaceID):
            return [
                "vm", "base", "open",
                "--workspace", workspaceID.uuidString,
                kind == .desktop ? "--desktop" : "--base",
                "--focus", "false",
            ]
        }
    }

    /// The request the coordinator tracks for this sheet's choices.
    var createRequest: MachineCreateRequest {
        MachineCreateRequest(
            mode: mode,
            kind: kind,
            name: supportsName ? trimmedName : nil,
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

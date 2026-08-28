import Foundation
import Observation

/// State behind the New Machine sheet: what the person picked, what the plan
/// allows, and the one create call. The model never talks to the backend
/// itself; ``create()`` hands the `cmux vm …` arguments to the injected
/// launcher so the sheet, the ＋ button, the CLI, and the palette share one
/// create-and-attach path (`CloudVMActionLauncher` → `cmux vm new`).
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
        case created
        case cancelled
    }

    /// Starts the CLI with `arguments`; returns false when it could not launch
    /// (sign-out raced the click). The completion carries the CLI's exit
    /// status and combined output, which is the error text on failure.
    typealias Launch = @MainActor ([String], @escaping @MainActor (CloudVMActionLauncher.Completion) -> Void) -> Bool

    /// Memory sizes the backend accepts (`VM_MEMORY_OPTIONS_MB` in
    /// `web/services/vms/entitlements.ts`); the plan ceiling trims the tail.
    static let memoryOptionsMb: [Int] = [2048, 4096, 8192, 16384, 24576, 32768]
    /// Mirrors `maxMemoryMbForPlan`: the free machine is a full-size computer;
    /// paid plans unlock the largest size.
    static func maxMemoryMb(planId: String?) -> Int {
        planId == nil || planId == "free" ? 24576 : 32768
    }
    /// Mirrors `defaultMemoryMbForPlan`: 24 GB, never above the plan's max.
    static func defaultMemoryMb(planId: String?) -> Int {
        min(24576, maxMemoryMb(planId: planId))
    }

    let mode: Mode
    let plan: MachinePlanSnapshot?
    let imageKinds: [VMImageKindOption]

    var name: String = ""
    var kind: VMMachineKind = .desktop
    var memoryMb: Int
    private(set) var isCreating = false
    /// The CLI's output when the last create failed; nil once a retry starts.
    private(set) var errorText: String?
    private(set) var outcome: Outcome?
    /// The machine `cmux vm new` reported as created even though the command
    /// then failed (opening its terminal, the desktop split). Once set, the
    /// sheet never runs the create again: Retry would mint a second machine.
    private(set) var createdMachineID: String?

    /// Recognizes the CLI's "Created Cloud VM <id>" line in `output`. The
    /// format is the CLI's own localized string, so the match follows the
    /// user's language instead of a hard-coded English prefix.
    static func createdMachineID(fromOutput output: String) -> String? {
        let format = String(localized: "cli.vm.create.createdCloudVM", defaultValue: "Created Cloud VM %@")
        let parts = format.components(separatedBy: "%@")
        guard parts.count == 2 else { return nil }
        let prefix = parts[0], suffix = parts[1]
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(prefix), line.hasSuffix(suffix), line.count > prefix.count + suffix.count else { continue }
            let id = String(line.dropFirst(prefix.count).dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            if id.count <= 128, !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) { return id }
        }
        return nil
    }

    /// Set by the presenter: called once when the sheet should close.
    var onFinished: (@MainActor (Outcome) -> Void)?

    private let launch: Launch

    init(
        mode: Mode,
        plan: MachinePlanSnapshot?,
        imageKinds: [VMImageKindOption],
        launch: @escaping Launch
    ) {
        self.mode = mode
        self.plan = plan
        self.imageKinds = imageKinds
        self.launch = launch
        self.memoryMb = Self.defaultMemoryMb(planId: plan?.planId)
    }

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
    var planMeterText: String? {
        guard let plan else { return nil }
        // The new machine counts toward the ceiling once it exists.
        let format = plan.isSingleMachinePlan
            ? String(localized: "machines.new.plan.single", defaultValue: "%1$d of 1 machine in use")
            : String(localized: "machines.new.plan.multi", defaultValue: "%1$d of %2$d machines in use")
        return String(format: format, plan.activeCount, plan.maxActiveVms)
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
    var cliArguments: [String] {
        switch mode {
        case .newMachine:
            var arguments = ["vm", "new", kind == .desktop ? "--desktop" : "--base"]
            if supportsSize {
                arguments += ["--size", String(memoryMb)]
            }
            if let trimmedName {
                arguments += ["--name", trimmedName]
            }
            return arguments
        case .base(let workspaceID):
            return [
                "vm", "base", "open",
                "--workspace", workspaceID.uuidString,
                kind == .desktop ? "--desktop" : "--base",
            ]
        }
    }

    func create() {
        guard !isCreating, outcome == nil else { return }
        if createdMachineID != nil {
            // The machine already exists; the primary button reads "Done".
            finish(.created)
            return
        }
        isCreating = true
        errorText = nil
        let started = launch(cliArguments) { [weak self] completion in
            guard let self else { return }
            self.isCreating = false
            if completion.succeeded {
                self.finish(.created)
            } else {
                let output = completion.output.trimmingCharacters(in: .whitespacesAndNewlines)
                let safeOutput = CloudVMActionLauncher.safeUserFacingOutput(output)
                if case .newMachine = self.mode, let id = Self.createdMachineID(fromOutput: output) {
                    self.createdMachineID = id
                    self.errorText = String(
                        format: String(
                            localized: "machines.new.error.createdOpenFailed",
                            defaultValue: "Machine %1$@ was created, but opening it failed. Open it from the Machines list.\n\n%2$@"
                        ),
                        id,
                        safeOutput ?? String(
                            localized: "machines.new.error.detailsHidden",
                            defaultValue: "Additional technical details are available in logs."
                        )
                    )
                    return
                }
                self.errorText = safeOutput
                    ?? String(localized: "machines.new.error.generic", defaultValue: "The machine could not be created.")
            }
        }
        if !started {
            isCreating = false
            errorText = String(
                localized: "machines.new.error.launch",
                defaultValue: "cmux could not start the create command. Sign in and try again."
            )
        }
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

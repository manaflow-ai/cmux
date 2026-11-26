public import CmuxNextCloud
import CmuxNextCompat
public import Foundation

// The Cloud side of a start the App runs (CloudStartChat): what it may copy, and the steps and
// size its card shows. Pure values; the App keeps the machine, the copy and the chat.
extension AgentPaneCloudStart {
    /// A step of the start as the page's card shows it (``progress(_:to:)``).
    public nonisolated struct Step: Sendable, Equatable {
        public var name: String
        public var folder: String?
        public var machine: String?
        public var size: String?
        public var cloneState: String?
        public var clonePhase: String?
        public var cloneStartedAt: Double?
        public var cloneFinishedAt: Double?
        public var environmentId: String?
        public var setupState: String?
        public var setupStatus: String?
        public var setupStartedAt: Double?
        public var setupFinishedAt: Double?
        public var setupError: String?
        public var setupHasScript: Bool?
        /// The seed's or copy's live progress (`cmux link seed push`'s stderr lines, ``SeedProgress``).
        public var cloneProgress: SeedProgress?
        /// A copy past the copy's limits sent a first pass: the files it left on this Mac (the chat asks for them). The
        /// card says the folder is partial, never complete. Nil for a copy sent whole.
        public var leftOnMac: Int64?

        public init(name: String, folder: String? = nil, machine: String? = nil, size: String? = nil,
                    cloneState: String? = nil, clonePhase: String? = nil,
                    cloneStartedAt: Double? = nil, cloneFinishedAt: Double? = nil,
                    environmentId: String? = nil, setupState: String? = nil, setupStatus: String? = nil,
                    setupStartedAt: Double? = nil, setupFinishedAt: Double? = nil,
                    setupError: String? = nil, setupHasScript: Bool? = nil, start: CloudStartInfo? = nil, leftOnMac: Int64? = nil) {
            (self.name, self.folder, self.machine, self.size, self.leftOnMac) = (name, folder, machine, size, leftOnMac)
            (self.cloneStartedAt, self.cloneFinishedAt) = (cloneStartedAt, cloneFinishedAt)
            (self.cloneState, self.clonePhase) = (cloneState, clonePhase)
            let setup = start?.setup
            (self.environmentId, self.setupState, self.setupStatus) = (start?.environmentId ?? environmentId, setup?.state ?? setupState, setup?.status ?? setupStatus)
            (self.setupStartedAt, self.setupFinishedAt) = (setup?.startedAt ?? setupStartedAt, setup?.finishedAt ?? setupFinishedAt)
            (self.setupError, self.setupHasScript) = (setup?.error ?? setupError, setup?.hasScript ?? setupHasScript)
        }
    }

    /// The folder step while its seed or copy runs: the clone row's live progress.
    public nonisolated static func copying(_ progress: SeedProgress, folder: String?, machine: String?, size: String?) -> Step {
        var step = Step(name: "folder", folder: folder, machine: machine, size: size, cloneState: "running", clonePhase: progress.phase)
        step.cloneProgress = progress
        return step
    }

    /// Tells the page's card `step` as it begins.
    @MainActor public func progress(_ step: Step, to view: AgentPaneView) {
        progress(step.name, folder: step.folder, machine: step.machine, size: step.size,
                 cloneState: step.cloneState, clonePhase: step.clonePhase,
                 cloneStartedAt: step.cloneStartedAt, cloneFinishedAt: step.cloneFinishedAt,
                 environmentId: step.environmentId, setupState: step.setupState, setupStatus: step.setupStatus,
                 setupStartedAt: step.setupStartedAt, setupFinishedAt: step.setupFinishedAt,
                 setupError: step.setupError, setupHasScript: step.setupHasScript,
                 cloneProgress: step.cloneProgress, leftOnMac: step.leftOnMac, to: view)
    }

    /// A machine's size in the card's words: "4 CPU · 16 GB".
    public nonisolated static func sizeText(_ size: CloudMachine.Size?) -> String? {
        guard let cpu = size?.cpu, cpu > 0 else { return nil }
        guard let memory = size?.memoryMb, memory > 0 else { return "\(cpu) CPU" }
        return "\(cpu) CPU · \(Int((Double(memory) / 1024).rounded())) GB"
    }

    /// Whether `folder` is what the send may copy: for a folder the page named, exactly the upload
    /// root the pane checked against its roots; for the tab's own folder (no `cwd`), only that folder
    /// itself, never a Git working copy found above it, which no check covered (a tab in
    /// /repo/project never uploads /repo, its siblings and its history).
    /// The tab's own folder also never when it is the home folder or above it, by its canonical
    /// path too (a tab in /Users would copy every home folder's credentials).
    ///
    /// The rule is Rust's (cmux-cloud-start-core `start::uploads`); this reads the disk for it: the
    /// canonical and standardized spellings, and the working copy's git folders only when asked.
    public nonisolated func uploads(_ folder: CloudMoveFolder, home: String? = NSHomeDirectory()) -> Bool {
        func standard(_ path: String) -> String { (path as NSString).standardizingPath }
        var paths: [String] = [], homes: [String] = []
        if cwd == nil, folder.subpath.isEmpty {
            let canonicalHome = home.flatMap(AgentHome.canonical) ?? home
            paths = [folder.root, AgentHome.canonical(folder.root)].compactMap { $0 }.map(standard)
            homes = [canonicalHome, home].compactMap { $0 }.map(standard)
        }
        switch CloudStartCore().uploads(cwdGiven: cwd != nil, uploadRoot: uploadRoot, root: folder.root, subpath: folder.subpath,
                                        paths: paths, homes: homes) {
        case .yes: return true
        case .no: return false
        case .ifGitFoldersInside: return Self.gitFoldersAreInside(folder.root) // its git folders are copied too
        }
    }
}

extension AgentPaneCloudStart {
    package static var localOnlyMessage: String {
        String(localized: "cloud.start.localOnlyModel", defaultValue: "This model runs locally. Choose a Cloud model or run the chat on this computer.", bundle: .module.inAppLanguage)
    }

    /// Refuse local-only profiles or offer setup for a Cloud connection that can be added.
    @MainActor public func connectionRefusalReply(for choice: CloudSetup.Choice) -> [String: Any]? {
        if choice == .localOnly {
            return AgentPaneReply.failure(code: "cloud_model_local_only", message: Self.localOnlyMessage,
                                          details: nil, retryable: false, origin: "native")
        }
        guard case .setup(let family, let model) = choice else { return nil }
        // A project needs the planner's sized destination before Settings can sign in on it.
        if family == "claude", !home { return nil }
        return Self.cloudSetupReply(family: family, model: model)
    }

    private static func cloudSetupReply(family: String, model: String?, machine: String? = nil) -> [String: Any] {
        var details = ["family": family, "model": model ?? ""]
        details["machine"] = machine
        return AgentPaneReply.failure(code: "cloud_setup_required", message: "cloud_setup_required",
                                     details: details, retryable: false, origin: "native")
    }

    /// Offer setup only after the machine reports no usable sign-in and the local connection
    /// list confirms an addable connection is missing.
    @MainActor public func needsConnectionReply(_ message: String, machine: String? = nil, setup: CloudSetup) async -> [String: Any] {
        let unrouted = await setup.unrouted(harness: harness, model: model, account: account)
        let choice = if let unrouted {
            CloudSetup.Choice.setup(family: unrouted.family, model: unrouted.model)
        } else {
            await setup.choose(harness: harness, model: model, account: account)
        }
        guard case .setup(let family, let model) = choice else {
            return AgentPaneReply.failure(code: "cloud_start_failed", message: message, details: nil, retryable: true, origin: "native")
        }
        if !CloudSetup.setupFamilies.contains(family) {
            return AgentPaneReply.failure(code: "cloud_start_failed", message: message, details: nil, retryable: true, origin: "native")
        }
        return Self.cloudSetupReply(family: family, model: model, machine: machine)
    }
}

extension CloudSetup {
    /// The credential for this send on the resolved machine.
    public func launchReadiness(for start: AgentPaneCloudStart, checkMachineLogin: Bool = true) async -> (choice: Choice, refusal: Refusal?) {
        let ready = checkMachineLogin ? await readyClaudeMachines(for: start) : []
        return await launchReadiness(harness: start.harness, model: start.model, account: start.account, readyClaude: !ready.isEmpty)
    }

    public func readyClaudeMachines(for start: AgentPaneCloudStart) async -> [String] {
        guard Self.family(of: start.harness) == "claude" else { return [] }
        return await readyClaudeMachines(machine: start.machine, environment: start.environment)
    }

    /// The readiness choice and candidate machines used by the first-send planner.
    package func plannerReadiness(for start: AgentPaneCloudStart) async -> (choice: Choice, machines: Set<String>) {
        let ready = await readyClaudeMachines(for: start)
        let choice = await launchReadiness(harness: start.harness, model: start.model, account: start.account, readyClaude: !ready.isEmpty).choice
        return (choice, Set(ready))
    }
}

import CmuxSurfaceCatalogModel
import Foundation

/// What the Cloud panel's "Get started" card shows, as plain values.
///
/// Three steps take a new account from "I have cmux" to "an agent is working
/// on my repo on a Cloud machine with my API keys": add keys, create a
/// machine, start an agent. Each step checks itself from the same state the
/// rest of the panel already trusts, so the card never asks the user to tick
/// anything and never disagrees with the tree beside it:
///
/// - keys: the secrets vault count;
/// - machine: the rows the Cloud Machines tree lists and the active count its
///   header shows (``machineCount(listedMachines:headerActiveCount:creatingCount:)``);
/// - agent: an agent on a Cloud terminal whose run has not failed, by the
///   tree's own failure predicate (``hasCloudAgent(in:unreadFailureTerminalIDs:)``).
///
/// The card waits for the first machine-list read and hides while that read
/// is failing (the panel's own status owns that space). Finishing every step
/// shows a quiet "You're set up" state; the panel retires the card the next
/// time it opens after the person saw that state (``retiresOnOpen(hasSeenCompletion:)``),
/// never while they are looking at it. Closing it retires it at once.
struct CloudGettingStartedChecklist: Equatable {
    enum Step: String, CaseIterable, Equatable, Sendable {
        case addKeys
        case createMachine
        case startAgent
    }

    /// The state the panel reads; the model derives everything else from it.
    struct Input: Equatable {
        /// Secrets in the vault. `nil` means no vault is wired into this
        /// build, so the keys step is left out instead of never checking.
        var secretCount: Int?
        /// Machines the tree lists or the header counts, plus creates in
        /// flight: ``CloudGettingStartedChecklist/machineCount(listedMachines:headerActiveCount:creatingCount:)``.
        var machineCount: Int
        /// Whether a Cloud machine terminal runs an agent that has not failed:
        /// ``CloudGettingStartedChecklist/hasCloudAgent(in:unreadFailureTerminalIDs:)``.
        var hasCloudAgent: Bool
        /// The first machine-list read finished.
        var hasLoadedMachines: Bool
        /// The machine-list read is currently failing or reconnecting.
        var hasListProblem: Bool
        /// The user closed the card, or a previous panel showed it finished.
        var isDismissed: Bool
    }

    /// The persisted dismissal, shared with the panel's other banners.
    static let dismissalID = "cloud.gettingStarted"
    /// Bump to show the card again after a material change to its steps.
    static let dismissalSignature = "v1"
    /// Persisted once the person has seen the finished card, so the next
    /// panel open retires it. Stored in the same dismissal store.
    static let completionSeenID = "cloud.gettingStarted.completionSeen"

    /// The exact command step 3 teaches. `<repo>` is literal: the user
    /// replaces it with `owner/repo` or a clone URL.
    static func startAgentCommand(repo: String? = nil, agent: String = "claude") -> String {
        let trimmed = repo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let target = trimmed.isEmpty ? "<repo>" : trimmed
        return "cmux vm clone \(target) --agent \(agent)"
    }

    /// Fallback for the keys step when the vault exists but its sheet is not
    /// wired: the CLI import reads well-known names from the login shell.
    static let importKeysCommand = "cmux vm secrets import --from-shell"

    /// How many machines step 2 sees, from the sources the Cloud Machines
    /// section already shows: the rows the tree lists (the fleet list plus
    /// machines the catalog discovered first, `MachineSnapshotBuilder.includingCatalogMachines`)
    /// and the header's active count (`MachinesPanelViewModel.visibleUsage`).
    /// Either one alone has lagged the other by a list read, which left the
    /// card on "Create a machine" beside a header reading 1/5.
    /// - Parameters:
    ///   - listedMachines: Machine rows the tree lists, deletes in flight excluded.
    ///   - headerActiveCount: The header's active count, nil before the plan loads.
    ///   - creatingCount: Creates still running or reconciling.
    static func machineCount(listedMachines: Int, headerActiveCount: Int?, creatingCount: Int) -> Int {
        max(listedMachines, headerActiveCount ?? 0) + creatingCount
    }

    /// Whether a Cloud machine terminal runs an agent whose run has not
    /// failed: the signal that step 3 happened, whichever entrypoint started
    /// the agent. A running agent or one that finished cleanly counts; one
    /// whose process exited badly, or that reported an error this Mac has not
    /// read, does not (`CloudTerminalExitPresentation.reportsFailure`, the
    /// predicate that paints the tree's amber mark). A failed first run
    /// therefore leaves step 3 open instead of finishing the card.
    /// - Parameters:
    ///   - snapshot: The panel's catalog, deletes in flight excluded.
    ///   - unreadFailureTerminalIDs: Per machine, the unread terminals whose
    ///     notification reports a failure (`CloudNotificationSyncHub`).
    static func hasCloudAgent(
        in snapshot: SurfaceCatalogSnapshot,
        unreadFailureTerminalIDs: [String: Set<String>] = [:]
    ) -> Bool {
        snapshot.resources.contains { resource in
            guard resource.agent != nil, case .cloud(let machineID) = resource.machine else { return false }
            let reportedError = unreadFailureTerminalIDs[machineID]?.contains(resource.id.key) == true
            return !CloudTerminalExitPresentation.reportsFailure(resource, hasUnreadFailureNotification: reportedError)
        }
    }

    /// The panel retires a finished card at the first settled read after it
    /// opens, once the person has seen the finished state in an earlier
    /// panel. A card that finished while the panel was closed shows
    /// "You're set up" once first.
    static func retiresOnOpen(hasSeenCompletion: Bool) -> Bool {
        hasSeenCompletion
    }

    /// Whether the panel closing now counts as the person having seen the
    /// finished card: it was on screen and every step was done.
    static func marksCompletionSeen(_ checklist: CloudGettingStartedChecklist) -> Bool {
        checklist.isVisible && checklist.isComplete
    }

    let steps: [Step]
    let completed: Set<Step>
    let isVisible: Bool

    init(_ input: Input) {
        var steps = Step.allCases
        if input.secretCount == nil {
            steps.removeAll { $0 == .addKeys }
        }
        var completed = Set<Step>()
        if let count = input.secretCount, count > 0 { completed.insert(.addKeys) }
        if input.machineCount > 0 { completed.insert(.createMachine) }
        if input.hasCloudAgent { completed.insert(.startAgent) }
        self.steps = steps
        self.completed = completed.intersection(steps)
        // A finished card stays visible as "You're set up"; the panel
        // retires it on a later open (see `retiresOnOpen`).
        isVisible = !input.isDismissed
            && input.hasLoadedMachines
            && !input.hasListProblem
    }

    /// The first unfinished step in order. Keys come first on purpose: an
    /// agent started on a machine without them stops at a login prompt.
    var current: Step? {
        steps.first { !completed.contains($0) }
    }

    var completedCount: Int { completed.count }
    var totalCount: Int { steps.count }
    var isComplete: Bool { current == nil }

    /// 0...1 for the progress ring.
    var progress: Double {
        totalCount == 0 ? 1 : Double(completedCount) / Double(totalCount)
    }

    func isDone(_ step: Step) -> Bool { completed.contains(step) }
}

extension CloudGettingStartedChecklist {
    /// The finished card's title.
    static var completedTitle: String {
        String(localized: "cloud.gettingStarted.done.title", defaultValue: "You\u{2019}re set up")
    }

    /// The finished card's one line: what to do next time.
    static var completedDetail: String {
        String(
            localized: "cloud.gettingStarted.done.detail",
            defaultValue: "Start another agent any time with cmux vm clone."
        )
    }
}

extension CloudGettingStartedChecklist.Step {
    var title: String {
        switch self {
        case .addKeys:
            return String(localized: "cloud.gettingStarted.keys.title", defaultValue: "Add your API keys")
        case .createMachine:
            return String(localized: "cloud.gettingStarted.machine.title", defaultValue: "Create a machine")
        case .startAgent:
            return String(localized: "cloud.gettingStarted.agent.title", defaultValue: "Start an agent on a repo")
        }
    }

    /// One line under the current step: why it matters, not how it works.
    var detail: String {
        switch self {
        case .addKeys:
            return String(
                localized: "cloud.gettingStarted.keys.why",
                defaultValue: "Every machine gets them, so agents sign in on their own."
            )
        case .createMachine:
            return String(
                localized: "cloud.gettingStarted.machine.why",
                defaultValue: "It keeps running after you close your laptop."
            )
        case .startAgent:
            return String(
                localized: "cloud.gettingStarted.agent.why",
                defaultValue: "Clones a repo onto a machine and starts the agent there."
            )
        }
    }

    var symbolName: String {
        switch self {
        case .addKeys: return "key"
        case .createMachine: return "cloud"
        case .startAgent: return "sparkles"
        }
    }

    /// The docs page for the step, on the public docs site.
    var learnMoreURL: URL {
        switch self {
        case .addKeys:
            return CloudDocsLinks.secrets
        case .createMachine:
            return CloudDocsLinks.machines
        case .startAgent:
            return CloudDocsLinks.openRepo
        }
    }

    var accessibilityIdentifier: String {
        "CloudGettingStarted.\(rawValue)"
    }
}

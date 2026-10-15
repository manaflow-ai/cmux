import CmuxSurfaceCatalogModel
import Foundation

/// What the Cloud panel's "Get started" card shows, as plain values.
///
/// Three steps take a new account from "I have cmux" to "an agent is working
/// on my repo on a Cloud machine with my API keys": add keys, create a
/// machine, start an agent. Each step checks itself from state the panel
/// already reads (the secrets vault count, the machine list, agent badges in
/// the surface catalog), so the card never asks the user to tick anything.
///
/// The card stays out of the way: it waits for the first machine-list read,
/// hides while that read is failing (the panel's own status owns that space),
/// and disappears for good once the user closes it or finishes every step.
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
        /// Machines on the list plus creates still in flight.
        var machineCount: Int
        /// Whether any Cloud machine terminal carries an agent badge.
        var hasCloudAgent: Bool
        /// The first machine-list read finished.
        var hasLoadedMachines: Bool
        /// The machine-list read is currently failing or reconnecting.
        var hasListProblem: Bool
        /// The user closed the card, or a previous session finished it.
        var isDismissed: Bool
    }

    /// The persisted dismissal, shared with the panel's other banners.
    static let dismissalID = "cloud.gettingStarted"
    /// Bump to show the card again after a material change to its steps.
    static let dismissalSignature = "v1"

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

    /// Whether any terminal on a Cloud machine carries an agent badge: the
    /// signal that step 3 happened, whichever entrypoint started the agent.
    static func hasCloudAgent(in snapshot: SurfaceCatalogSnapshot) -> Bool {
        snapshot.resources.contains { resource in
            guard resource.agent != nil, case .cloud = resource.machine else { return false }
            return true
        }
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
        let isComplete = steps.allSatisfy { completed.contains($0) }
        isVisible = !input.isDismissed
            && input.hasLoadedMachines
            && !input.hasListProblem
            && !isComplete
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
                localized: "cloud.gettingStarted.keys.detail",
                defaultValue: "Every machine gets them, so Claude Code and Codex sign in on their own. Values never pass through cmux servers."
            )
        case .createMachine:
            return String(
                localized: "cloud.gettingStarted.machine.detail",
                defaultValue: "A computer in the cloud that keeps running after you close your laptop."
            )
        case .startAgent:
            return String(
                localized: "cloud.gettingStarted.agent.detail",
                defaultValue: "Run this in any terminal. It clones the repo onto a machine and starts the agent there."
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

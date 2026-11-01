public import CmuxNextActions
public import CmuxNextBridge
public import CmuxNextDaemon
import Foundation

/// What Name from Activity reads from the App: the target workspace, a browser tab's live title,
/// acpmux's one-shot completion and the rename.
@MainActor
public protocol WorkspaceActivityNameHost: AnyObject {
    /// The invocation's workspace; nil when it targets none.
    func activityWorkspace(_ invocation: ActionInvocation) -> WorkspaceModel?
    /// A browser tab's live page title; nil for an incognito page (it never leaves memory, R102).
    func activityPageTitle(_ tab: TabModel) -> String?
    /// Whether acpmux runs, so ``activityComplete(_:)`` can answer.
    func activityHasAgents() -> Bool
    /// Runs one `_acpmux/complete` with `params` (`fallback` when its harness cannot answer here)
    /// and answers its text.
    func activityComplete(_ params: [String: any Sendable], fallback: [String: any Sendable]) async throws -> String
    /// Runs `body` on the daemon that owns `workspace`; false when it failed.
    func activityRun(_ workspace: WorkspaceModel, _ body: @escaping @Sendable (isolated DaemonConnection) async throws -> Void) async -> Bool
    /// Whether the daemon of `workspace` guards a rename by its name revision.
    func activityGuardsRevision(_ workspace: WorkspaceModel) -> Bool
}

extension WorkspaceActivityName {
    /// Why Name from Activity did not rename.
    public enum Refusal: Sendable, Equatable {
        case noWorkspace, nothingToNameFrom, noAgents, noName, oldDaemon
        case failed(String)

        /// What the person reads.
        public var text: String {
            switch self {
            case .noWorkspace: String(localized: "workspaceNaming.nameFromActivity.noWorkspace", defaultValue: "No workspace to name.", bundle: .module)
            case .nothingToNameFrom: String(localized: "workspaceNaming.nameFromActivity.nothing", defaultValue: "This workspace has no activity to name it from.", bundle: .module)
            case .noAgents: String(localized: "workspaceNaming.nameFromActivity.noAgents", defaultValue: "Name from Activity needs the agent service, which is not running.", bundle: .module)
            case .noName: String(localized: "workspaceNaming.nameFromActivity.noName", defaultValue: "The model did not suggest a name.", bundle: .module)
            case .oldDaemon: String(localized: "workspaceNaming.nameFromActivity.oldDaemon", defaultValue: "This workspace's machine runs an older cmux that cannot protect a rename made meanwhile.", bundle: .module)
            case let .failed(detail): String(localized: "workspaceNaming.nameFromActivity.failed", defaultValue: "Could not name the workspace: \(detail)", bundle: .module)
            }
        }
    }
}

/// Name from Activity (`workspace.nameFromActivity`, the workspace row's More > Options and the
/// palette): the workspace's tabs, as titles and short snippets (`WorkspaceActivityName`), go to the
/// cheapest model, and its answer becomes the person's own name for the workspace, so automatic
/// naming (`WorkspaceAutoNamer`) stops after it. Runs only when asked; nothing here is automatic.
@MainActor
public final class WorkspaceActivityNameActions {
    public static let actionID: ActionID = "workspace.nameFromActivity"
    /// Held for the registry's life: the bound action is its only owner.
    private let host: any WorkspaceActivityNameHost
    private let turns: AgentTurnStateStore

    public init(host: any WorkspaceActivityNameHost, turns: AgentTurnStateStore = .shared) {
        self.host = host
        self.turns = turns
    }

    public func bind(into registry: ActionRegistry) {
        _ = registry.bindEffect(Self.actionID) { [self] invocation in effect(invocation) }
    }

    func effect(_ invocation: ActionInvocation) -> ActionEffect {
        let host = host
        guard let workspace = host.activityWorkspace(invocation), let key = workspace.key else {
            return .refused(WorkspaceActivityName.Refusal.noWorkspace.text)
        }
        // A rename the person makes while the model answers wins: the daemon refuses this one once
        // the name revision read here has moved on. A daemon without that guard is refused, so a
        // late reply can never overwrite the person's name.
        guard host.activityGuardsRevision(workspace) else { return .refused(WorkspaceActivityName.Refusal.oldDaemon.text) }
        let activity = WorkspaceActivityName.read(workspace, turns: turns, page: host.activityPageTitle)
        guard !activity.isEmpty else { return .refused(WorkspaceActivityName.Refusal.nothingToNameFrom.text) }
        guard host.activityHasAgents() else { return .refused(WorkspaceActivityName.Refusal.noAgents.text) }
        let revision = workspace.nameRevision
        let params = activity.completionParams, fallback = activity.completionFallbackParams
        // action-wait-allow: the name comes from a model another process runs (acpmux's completion); nothing local can stand in for it
        return .waiting(.externalProcess) {
            let reply: String
            do {
                reply = try await host.activityComplete(params, fallback: fallback)
            } catch {
                return ActionWorkFailure(WorkspaceActivityName.Refusal.failed(error.localizedDescription).text)
            }
            guard let name = WorkspaceActivityName.name(fromReply: reply) else {
                return ActionWorkFailure(WorkspaceActivityName.Refusal.noName.text)
            }
            // No `source`: the daemon records the person's own name (`user`).
            let renamed = await host.activityRun(workspace) { connection in
                _ = try await connection.renameWorkspace(key, to: name, expectedNameRevision: revision)
            }
            return renamed ? nil : ActionWorkFailure(WorkspaceActivityName.Refusal.failed(name).text)
        }
    }
}

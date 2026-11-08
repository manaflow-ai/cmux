public import CmuxNextActions
import CmuxNextDaemon
import Foundation

/// The palette's git worktree and checkpoint actions (GitActionCatalog): each sends the session
/// host the operation its `cmux git` verb sends, in the folder of the invocation's tab, on that
/// machine's ``AgentPaneGitLink``. The session host does the work and says why it refuses; this
/// only names the folder, mints the idempotency key and reports the outcome. Worktree writes run
/// only on this Mac, as the CLI's do (`localize_commit_paths`).
@MainActor
public struct GitRepositoryActions {
    /// Where an invocation's git runs: its tab's folder on that tab's machine.
    public struct Place {
        public var link: AgentPaneGitLink
        public var cwd: String

        public init(link: AgentPaneGitLink, cwd: String) {
            self.link = link
            self.cwd = cwd
        }
    }

    /// One action's request: the session host operation and its fields beyond `path`.
    struct Request: Equatable {
        var operation: String
        var params: [String: JSONValue]
        /// A worktree write: refused for a tab on another machine.
        var localOnly: Bool

        /// The request `id` sends for `arguments`; nil for an id this type does not handle.
        static func make(_ id: ActionID, arguments: [String: ActionValue]) -> Request? {
            let text = { (name: String) -> String? in
                guard let value = arguments[name]?.stringValue?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
                return value
            }
            switch id {
            case "git.worktree.create":
                var params: [String: JSONValue] = [:]
                if let name = text("name") { params["name"] = .string(name) }
                if let base = text("base") { params["base"] = .string(base) }
                return Request(operation: "git.worktree.create", params: params, localOnly: true)
            case "git.worktree.apply":
                return Request(operation: "git.worktree.apply", params: [:], localOnly: true)
            case "git.worktree.remove":
                let discard = arguments["discard"]?.boolValue == true
                return Request(operation: "git.worktree.remove", params: discard ? ["discard": .bool(true)] : [:], localOnly: true)
            case "git.checkpoint.create":
                return Request(operation: "git.checkpoint.create", params: ["reason": .string("manual")], localOnly: false)
            default:
                return nil
            }
        }
    }

    static let actionIDs: [ActionID] = ["git.worktree.create", "git.worktree.apply", "git.worktree.remove", "git.checkpoint.create"]

    private let place: @MainActor (ActionInvocation) -> Place?
    private let announce: @MainActor (String) -> Void

    /// - Parameters:
    ///   - place: The invocation's tab folder and its machine's link; nil when the tab has none.
    ///   - announce: Shows what a run did (a toast in the front window).
    public init(place: @escaping @MainActor (ActionInvocation) -> Place?, announce: @escaping @MainActor (String) -> Void) {
        self.place = place
        self.announce = announce
    }

    public func bind(into registry: ActionRegistry) {
        let (place, announce) = (place, announce)
        for id in Self.actionIDs {
            registry.bindEffect(id, effect: { invocation in
                guard let request = Request.make(id, arguments: invocation.arguments) else { return .done }
                guard let found = place(invocation), found.cwd.hasPrefix("/") else { return .refused(GitRepositoryStrings.noFolder) }
                guard found.link.isLocal || !request.localOnly else { return .refused(GitRepositoryStrings.thisMacOnly) }
                var params = request.params
                params["path"] = .string(found.cwd)
                let key = UUID().uuidString
                // action-wait-allow: git in the session host decides the result (a worktree add, its hooks, a capture); nothing local can stand in for it
                return .waiting(.externalProcess) {
                    do {
                        let answer = try await found.link.perform(request.operation, params: params, idempotencyKey: key)
                        announce(GitRepositoryStrings.done(request.operation, answer["value"] ?? answer))
                        return nil
                    } catch DaemonError.command(_, let message, _, _, _) {
                        return ActionWorkFailure(refusal: .unavailable, reason: message)
                    } catch {
                        return ActionWorkFailure(request.operation, error)
                    }
                }
            })
        }
    }
}

nonisolated enum GitRepositoryStrings {
    static var noFolder: String {
        text("git.noFolder", "This tab has no folder on this machine. Focus a terminal in the repository, then try again.")
    }

    static var thisMacOnly: String {
        text("git.thisMacOnly", "Git worktrees are made and removed only on this Mac, and this tab is on another machine.")
    }

    /// What the run says once `operation` answered `value` (its `MutationResult` value).
    static func done(_ operation: String, _ value: JSONValue) -> String {
        switch operation {
        case "git.worktree.create":
            String(format: text("git.worktreeCreated", "New worktree at %@"), value["root"]?.stringValue ?? "")
        case "git.worktree.apply":
            String(format: text("git.worktreeApplied", "Applied the worktree's work to %@"), value["main_root"]?.stringValue ?? "")
        case "git.worktree.remove":
            text("git.worktreeRemoved", "Removed the worktree and its branch")
        default:
            text("git.checkpointCreated", "Created a git checkpoint")
        }
    }

    private static func text(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "GitActions", bundle: .module)
    }
}

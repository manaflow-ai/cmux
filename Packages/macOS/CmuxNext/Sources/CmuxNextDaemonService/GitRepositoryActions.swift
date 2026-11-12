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
        /// The tab whose folder `cwd` is, and its machine: what ``pinned(_:at:)`` aims a run at.
        public var tab: ActionTargetRef?
        public var machineID: String?

        public init(link: AgentPaneGitLink, cwd: String, tab: ActionTargetRef? = nil, machineID: String? = nil) {
            self.link = link
            self.cwd = cwd
            self.tab = tab
            self.machineID = machineID
        }
    }

    /// `invocation` aimed at `place`'s tab, machine and folder, for a run that asks first (Remove
    /// Git Worktree): the confirmed run removes the worktree its question was about, not the one a
    /// tab selected or a `cd` while the question is up names. Nil when `place` names no tab.
    public static func pinned(_ invocation: ActionInvocation, at place: Place?) -> ActionInvocation? {
        guard let place, let tab = place.tab else { return nil }
        var pinned = invocation.onMachine(place.machineID)
        pinned.target = tab
        pinned.arguments[pinnedPathName] = .string(place.cwd)
        // The confirmed run answers the question's click, not the first press.
        pinned.inputTimestamp = nil
        return pinned
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

    /// The argument a confirmed run carries naming the folder its question was about
    /// (``pinned(_:at:)``). It only narrows a run: one whose tab is now in
    /// another folder is refused, and the folder git runs in is still the tab's own.
    public static let pinnedPathName = "pinnedPath"

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
                // An in-app remove ran through the question, which pins the folder it asked about; one
                // without a pin had no folder at the press, and must not take one that turned up since.
                if id == "git.worktree.remove", !invocation.viaControlSocket, invocation[Self.pinnedPathName] == nil {
                    return .refused(GitRepositoryStrings.noFolder)
                }
                guard let found = place(invocation), found.cwd.hasPrefix("/") else { return .refused(GitRepositoryStrings.noFolder) }
                // A run that asked first carries the folder it asked about; the tab has moved on since.
                if let pinned = invocation[Self.pinnedPathName]?.stringValue, pinned != found.cwd {
                    return .refused(GitRepositoryStrings.folderChanged)
                }
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

extension GitRepositoryActions {
    // The question Remove Git Worktree asks before it runs (the registry's destructive gate): a
    // remove deletes the worktree's folder with the files git ignores (an `.env`), and with
    // `discard` its uncommitted work too.
    public nonisolated static var removeTitle: String { GitRepositoryStrings.text("git.removeTitle", "Remove this worktree?") }
    public nonisolated static var removeButton: String { GitRepositoryStrings.text("git.removeButton", "Remove Worktree") }

    public nonisolated static func removeBody(discard: Bool) -> String {
        discard
            ? GitRepositoryStrings.text("git.removeDiscardBody",
                                        "This deletes the worktree's folder and its branch, with its uncommitted changes and the files git ignores, such as .env. This can't be undone.")
            : GitRepositoryStrings.text("git.removeBody",
                                        "This deletes the worktree's folder and its branch, with the files git ignores, such as .env. This can't be undone.")
    }
}

nonisolated enum GitRepositoryStrings {
    static var noFolder: String {
        text("git.noFolder", "This tab has no folder on this machine. Focus a terminal in the repository, then try again.")
    }

    static var folderChanged: String {
        text("git.folderChanged", "This tab moved to another folder while you were asked. Nothing was removed; run it again from the worktree.")
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

    static func text(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "GitActions", bundle: .module)
    }
}

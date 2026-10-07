public import Foundation

/// Chooses the workspace a new REPL session binds to.
///
/// An explicit workspace (`--workspace`) must exist. The caller's workspace
/// (`CMUX_WORKSPACE_ID`) is a hint: the environment can be inherited from a
/// different cmux instance, so an id this instance does not know falls back
/// to the focused workspace, the same as a caller outside cmux. The
/// workspace of the cmux terminal the calling process runs in, when the
/// socket transport traced one, overrides both
/// (``caller(explicitHandle:caller:derived:)``).
public struct BrowserReplWorkspaceBinding {
    /// Why no workspace could be chosen.
    public enum Failure: Error, Equatable {
        /// The explicitly requested workspace does not exist in this instance.
        case explicitWorkspaceNotFound(UUID)
        /// The caller named a workspace with something that is not a
        /// workspace id (a ref a relay passed on unresolved, a blank value).
        case explicitWorkspaceInvalid(String)
        /// No window has a selected workspace.
        case noFocusedWorkspace
        /// The caller runs in a cmux terminal of `caller` and named another
        /// workspace, `requested`.
        case otherWorkspaceDenied(requested: UUID, caller: UUID)
        /// The caller runs in a cmux terminal of `caller` and asked for
        /// every workspace's sessions.
        case allWorkspacesDenied(caller: UUID)
    }

    private let exists: (UUID) -> Bool
    private let focused: () -> UUID?

    /// - Parameters:
    ///   - exists: Whether this instance has a workspace with the id.
    ///   - focused: The selected workspace of the key or frontmost window.
    public init(exists: @escaping (UUID) -> Bool, focused: @escaping () -> UUID?) {
        self.exists = exists
        self.focused = focused
    }

    /// - Parameters:
    ///   - explicitHandle: The workspace the caller named, as sent, or
    ///     `nil` when it named none. One that is not a workspace id fails:
    ///     an explicit choice never falls back.
    ///   - caller: The caller's own workspace from its environment, or `nil`.
    public func resolve(explicitHandle: String?, caller: UUID?) -> Result<UUID, Failure> {
        guard let explicitHandle else { return resolve(explicit: nil, caller: caller) }
        guard let explicit = UUID(uuidString: explicitHandle.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure(.explicitWorkspaceInvalid(explicitHandle))
        }
        return resolve(explicit: explicit, caller: caller)
    }

    /// - Parameters:
    ///   - explicit: The workspace the caller named, or `nil`.
    ///   - caller: The caller's own workspace from its environment, or `nil`.
    public func resolve(explicit: UUID?, caller: UUID?) -> Result<UUID, Failure> {
        resolveCaller(explicit: explicit, caller: caller).flatMap { found in
            switch found {
            case .inside(let workspace): .success(workspace)
            case .outside(let focused): focused.map { .success($0) } ?? .failure(.noFocusedWorkspace)
            }
        }
    }

    /// Where a call comes from.
    public enum Caller: Equatable, Sendable {
        /// A workspace of this instance: the one the caller named, or its own.
        case inside(UUID)
        /// Outside cmux: no workspace in the caller's environment, or one
        /// this instance does not know (another instance's), with the
        /// workspace focused now, if any. A named session such a caller
        /// asks for is one session per name, whatever is focused
        /// (``BrowserReplSessionRegistry/outsideSession(named:focusedWorkspace:make:)``).
        case outside(focused: UUID?)
    }

    /// Like ``resolve(explicitHandle:caller:)``, telling a caller outside
    /// cmux apart instead of binding it to the focused workspace.
    public func caller(explicitHandle: String?, caller: UUID?) -> Result<Caller, Failure> {
        guard let explicitHandle else { return resolveCaller(explicit: nil, caller: caller) }
        guard let explicit = UUID(uuidString: explicitHandle.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure(.explicitWorkspaceInvalid(explicitHandle))
        }
        return resolveCaller(explicit: explicit, caller: caller)
    }

    /// Like ``caller(explicitHandle:caller:)``, with the workspace the
    /// socket transport traced the calling process to.
    ///
    /// - Parameter derived: The workspace of the cmux terminal the calling
    ///   process runs in (``BrowserReplCallerLocality``), or `nil` when it
    ///   runs in none. A caller cannot choose it. When it is set it is the
    ///   caller's workspace: a `workspace_id` that names another one is
    ///   refused, and the environment's `caller` is ignored.
    public func caller(explicitHandle: String?, caller: UUID?, derived: UUID?) -> Result<Caller, Failure> {
        guard let derived else { return self.caller(explicitHandle: explicitHandle, caller: caller) }
        guard let explicitHandle else { return .success(.inside(derived)) }
        guard let explicit = UUID(uuidString: explicitHandle.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure(.explicitWorkspaceInvalid(explicitHandle))
        }
        guard explicit == derived else { return .failure(.otherWorkspaceDenied(requested: explicit, caller: derived)) }
        return .success(.inside(derived))
    }

    /// The sessions `list` and `reset` act on.
    public enum Scope: Equatable, Sendable {
        /// Every workspace's (`all_workspaces`).
        case allWorkspaces
        /// The caller's.
        case caller(Caller)
    }

    /// The sessions a `list` or `reset` call acts on. Only a caller that
    /// runs in no cmux terminal (`derived` is `nil`) may ask for every
    /// workspace's; see ``caller(explicitHandle:caller:derived:)``.
    public func scope(allWorkspaces: Bool, explicitHandle: String?, caller: UUID?, derived: UUID?) -> Result<Scope, Failure> {
        if allWorkspaces {
            if let derived { return .failure(.allWorkspacesDenied(caller: derived)) }
            return .success(.allWorkspaces)
        }
        return self.caller(explicitHandle: explicitHandle, caller: caller, derived: derived).map { .caller($0) }
    }

    private func resolveCaller(explicit: UUID?, caller: UUID?) -> Result<Caller, Failure> {
        if let explicit {
            return exists(explicit) ? .success(.inside(explicit)) : .failure(.explicitWorkspaceNotFound(explicit))
        }
        if let caller, exists(caller) {
            return .success(.inside(caller))
        }
        return .success(.outside(focused: focused()))
    }
}

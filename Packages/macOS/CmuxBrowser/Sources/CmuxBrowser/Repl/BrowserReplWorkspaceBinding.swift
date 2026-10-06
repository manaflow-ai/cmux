public import Foundation

/// Chooses the workspace a new REPL session binds to.
///
/// An explicit workspace (`--workspace`) must exist. The caller's workspace
/// (`CMUX_WORKSPACE_ID`) is a hint: the environment can be inherited from a
/// different cmux instance, so an id this instance does not know falls back
/// to the focused workspace, the same as a caller outside cmux.
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
        if let explicit {
            return exists(explicit) ? .success(explicit) : .failure(.explicitWorkspaceNotFound(explicit))
        }
        if let caller, exists(caller) {
            return .success(caller)
        }
        guard let focused = focused() else { return .failure(.noFocusedWorkspace) }
        return .success(focused)
    }
}

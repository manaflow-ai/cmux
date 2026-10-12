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

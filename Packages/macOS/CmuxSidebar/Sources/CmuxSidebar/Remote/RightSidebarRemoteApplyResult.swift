import Foundation

/// The outcome of applying a ``RightSidebarRemoteCommand`` through its
/// ``RightSidebarRemoteCommand/apply(target:host:strings:)`` method.
public enum RightSidebarRemoteApplyResult: Equatable, Sendable {
    /// The command succeeded with no payload.
    case ok
    /// A `getState` command succeeded, carrying the sidebar state.
    case state(RightSidebarRemoteState)
    /// The command failed; the associated value is a localized error message.
    case failure(String)
}

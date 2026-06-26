import Foundation

/// The result of resolving a ``RightSidebarRemoteTarget`` to a live window
/// once, before the interpreter runs. Mirrors the original single-pass
/// resolution of context, state, and preferred window.
@MainActor
public struct RightSidebarRemoteResolution {
    /// Whether a registered main window matched the target.
    public let contextExists: Bool
    /// Whether the matched window has a realized `NSWindow`.
    public let preferredWindowExists: Bool
    /// The addressed sidebar session, or `nil` when no state is available.
    public let session: (any RightSidebarRemoteSession)?

    /// Creates a resolution.
    public init(
        contextExists: Bool,
        preferredWindowExists: Bool,
        session: (any RightSidebarRemoteSession)?
    ) {
        self.contextExists = contextExists
        self.preferredWindowExists = preferredWindowExists
        self.session = session
    }
}

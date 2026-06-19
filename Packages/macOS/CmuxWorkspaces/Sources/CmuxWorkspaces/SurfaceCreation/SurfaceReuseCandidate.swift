public import Foundation

/// One existing surface a reuse lookup may match against, reduced to the two
/// facts the decision needs: the panel's identity in the workspace registry
/// and the value that decides whether it shows the requested content.
///
/// The `key` is an opaque identity the caller defines per surface kind: the
/// resolved file path for markdown and file-preview surfaces, or the right
/// sidebar tool mode. The resolver only compares keys for equality, so the app
/// target never has to surface its concrete `Panel` or `RightSidebarMode` types
/// to this package.
public struct SurfaceReuseCandidate<Key: Hashable & Sendable>: Sendable, Equatable {
    /// The workspace-registry identifier of the candidate panel.
    public let panelId: UUID

    /// The identity that decides whether this candidate already shows the
    /// requested content.
    public let key: Key

    /// Creates a reuse candidate.
    public init(panelId: UUID, key: Key) {
        self.panelId = panelId
        self.key = key
    }
}

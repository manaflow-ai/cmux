public import Foundation

/// Owns automatic checkpoint admission for one nested session restore pass.
///
/// Callers supply canonical identities and serialize access to this value.
/// The app's main-actor restore batch owns one instance across its containers.
public struct RestorePassCheckpointClaimStore: Sendable {
    /// A canonical agent kind and checkpoint, independent of command transport.
    public struct Checkpoint: Hashable, Sendable {
        private let kind: String
        private let sessionID: String

        /// Creates a checkpoint key from already canonicalized components.
        ///
        /// - Parameters:
        ///   - kind: The normalized agent kind.
        ///   - sessionID: The canonical checkpoint identifier.
        public init(kind: String, sessionID: String) {
            self.kind = kind
            self.sessionID = sessionID
        }
    }

    /// The result of claiming automatic startup for a checkpoint.
    public enum Claim: Equatable, Sendable {
        /// No restore pass is active, so the request is not tracked.
        case unscoped
        /// This request owns automatic startup in the current pass.
        case owner
        /// Another request already owns automatic startup in the current pass.
        case duplicate
    }

    private var depth = 0
    private var checkpoints: Set<Checkpoint> = []
    private var ownersByPanelID: [UUID: Checkpoint] = [:]

    /// Creates a store with no active pass or claims.
    public init() {}

    /// Whether an enclosing restore pass is active.
    public var isRestoring: Bool { depth > 0 }

    /// Begins a pass, retaining the claims of any enclosing pass.
    public mutating func beginRestorePass() { depth += 1 }

    /// Ends a pass and clears claims when the outermost pass ends.
    public mutating func endRestorePass() {
        guard depth > 0 else { return }
        depth -= 1
        if depth == 0 { reset() }
    }

    /// Claims automatic startup, with no limit on distinct checkpoints.
    ///
    /// - Parameter checkpoint: The canonical session being started.
    /// - Returns: Whether this request owns startup, is a duplicate, or is unscoped.
    public mutating func claim(_ checkpoint: Checkpoint) -> Claim {
        guard isRestoring else { return .unscoped }
        return checkpoints.insert(checkpoint).inserted ? .owner : .duplicate
    }

    /// Releases an owner's claim when its panel could not be attached.
    ///
    /// Only the request that received ``Claim/owner`` may call this method.
    /// - Parameter checkpoint: The checkpoint owned by the failed request.
    public mutating func release(_ checkpoint: Checkpoint) {
        checkpoints.remove(checkpoint)
        ownersByPanelID = ownersByPanelID.filter { $0.value != checkpoint }
    }

    /// Associates an owned claim with a panel for later container transfers.
    ///
    /// - Parameters:
    ///   - checkpoint: A checkpoint this request claimed as ``Claim/owner``.
    ///   - panelID: The attached panel that owns this claim.
    public mutating func recordOwner(_ checkpoint: Checkpoint, panelID: UUID) {
        guard isRestoring, checkpoints.contains(checkpoint) else { return }
        ownersByPanelID[panelID] = checkpoint
    }

    /// Releases only the failed panel's claim, leaving other owners intact.
    ///
    /// - Parameter panelID: The panel whose transfer failed.
    public mutating func release(panelID: UUID) {
        guard let checkpoint = ownersByPanelID.removeValue(forKey: panelID) else { return }
        release(checkpoint)
    }

    /// Ends every pass and clears all claims and panel associations.
    public mutating func reset() {
        depth = 0
        checkpoints.removeAll()
        ownersByPanelID.removeAll()
    }
}

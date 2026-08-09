public import Foundation

/// The seam through which ``ControlCommandCoordinator`` asks the app what kind
/// of object a raw UUID names.
///
/// A `kind:N` ref states its own kind, but the protocol also accepts raw UUID
/// strings, which carry none. Without an answer here the coordinator can only
/// consult the handle registry's mint history, and that is not a sound oracle:
/// dock-hosted objects may not be minted yet, and
/// ``ControlHandleRegistry/removeRef(kind:uuid:)`` erases what it knew. Live
/// topology is authoritative, so a surface UUID handed to `group_id` is
/// rejected rather than routed
/// (https://github.com/manaflow-ai/cmux/issues/9424).
@MainActor
public protocol ControlIdentityKindContext: AnyObject {
    /// The kinds a raw identifier is known to name in live app topology.
    ///
    /// An identity may hold more than one kind: a Window Dock owner id IS its
    /// owning window's id, so it answers as both.
    ///
    /// - Parameter uuid: The identifier to classify.
    /// - Returns: Every kind the identity currently names — empty when it names
    ///   nothing live — or `nil` when this conformer cannot classify at all, in
    ///   which case the coordinator falls back to the handle registry.
    func controlIdentityKinds(for uuid: UUID) -> Set<ControlHandleKind>?
}

extension ControlIdentityKindContext {
    /// Conformers that cannot classify opt out; the coordinator then falls back
    /// to the handle registry's mint history.
    public func controlIdentityKinds(for uuid: UUID) -> Set<ControlHandleKind>? {
        nil
    }
}

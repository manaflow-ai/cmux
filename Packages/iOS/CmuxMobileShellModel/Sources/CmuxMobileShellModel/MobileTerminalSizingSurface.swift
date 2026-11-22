public import CmuxTerminalSizing
public import Foundation

/// Whether this phone is attached to one shared terminal.
public enum MobileTerminalAttachment: Equatable, Sendable {
    /// Attached: viewport, input and replay flow normally.
    case attached
    /// The host dropped this view for a network reason and the phone is
    /// reconnecting it without user action.
    case reconnecting
    /// The host detached this view and it stays detached until the user
    /// reattaches. Viewport, input and replay stop for the surface.
    case detached(reason: TerminalDetachReason, at: Date?)

    /// Whether viewport reports, input and replays may be sent.
    public var allowsTerminalTraffic: Bool {
        if case .detached = self { return false }
        return true
    }
}

/// What the shell must do after a sizing event.
public enum MobileTerminalSizingEffect: Equatable, Sendable {
    /// Nothing beyond publishing the new state.
    case none
    /// Recover the surface through the normal replay path (network detach).
    case reconnect
    /// Ask the surface to report its viewport again so the phone learns the
    /// new effective grid through the viewport acknowledgement.
    case reassertViewport
}

/// The per-terminal shared sizing state kept by the phone.
///
/// A pure value with a reducer, so the rules (generation ordering, detach
/// handling, no automatic reattach) are testable without a Mac.
public struct MobileTerminalSizingSurface: Equatable, Sendable {
    /// The newest size state the host published, if any.
    public private(set) var state: TerminalSizingState?
    /// This phone's participant id as the host reports it.
    public private(set) var selfParticipantID: String?
    /// Whether this phone is attached.
    public private(set) var attachment: MobileTerminalAttachment
    /// Bumped whenever the surface should report its viewport again
    /// (reattach, or an owner change that moved the grid).
    public private(set) var viewportReassertGeneration: UInt64

    /// Creates an attached surface with no published state.
    public init() {
        state = nil
        selfParticipantID = nil
        attachment = .attached
        viewportReassertGeneration = 0
    }

    /// Applies a size state from a replay result or a `size_state` push.
    ///
    /// Older generations are dropped while the participant id is unchanged.
    /// A new participant id (a fresh attach after a host restart) resets the
    /// ordering. A size state proves the host serves this view again, so it
    /// ends a network reconnect. It never ends a user-visible detach.
    ///
    /// - Parameters:
    ///   - newState: The published state.
    ///   - selfID: This phone's participant id, if the host sent one.
    ///   - effectiveGrid: The grid the phone currently renders, if known.
    /// - Returns: `.reassertViewport` when the grid moved away from the
    ///   rendered grid, else `.none`.
    @discardableResult
    public mutating func applySizeState(
        _ newState: TerminalSizingState,
        selfParticipantID selfID: String?,
        effectiveGrid: TerminalGridSize?
    ) -> MobileTerminalSizingEffect {
        let sameParticipant = selfID == nil || selfID == selfParticipantID
        if let current = state, sameParticipant, newState.generation < current.generation {
            return .none
        }
        let previousSize = state?.size
        state = newState
        if let selfID { selfParticipantID = selfID }
        if attachment == .reconnecting { attachment = .attached }
        guard attachment.allowsTerminalTraffic,
              previousSize != newState.size,
              let effectiveGrid,
              effectiveGrid != newState.size else {
            return .none
        }
        viewportReassertGeneration &+= 1
        return .reassertViewport
    }

    /// Forgets the published state when the connection to the Mac ends.
    ///
    /// The next host (a relaunched Mac, or a new sizing host) restarts its
    /// generations under the same participant id, so the old generation must
    /// not order the new states. A user-visible detach stays: the host keeps
    /// it across the phone's reconnect.
    public mutating func connectionEnded() {
        state = nil
        selfParticipantID = nil
    }

    /// Applies a `detached` push.
    /// - Parameters:
    ///   - reason: The decoded reason and actor.
    ///   - at: When the host detached the view.
    /// - Returns: `.reconnect` only for a network drop.
    @discardableResult
    public mutating func applyDetached(
        reason: TerminalDetachReason,
        at: Date?
    ) -> MobileTerminalSizingEffect {
        if reason.reconnectsAutomatically {
            // A user-visible detach outranks a later network event: the host
            // keeps dropping this view until the user reattaches.
            guard attachment.allowsTerminalTraffic else { return .none }
            attachment = .reconnecting
            return .reconnect
        }
        attachment = .detached(reason: reason, at: at)
        return .none
    }

    /// Marks a successful `mobile.terminal.reattach`.
    /// - Parameters:
    ///   - newState: The size state the reattach answered with, if any.
    ///   - selfID: This phone's participant id from the answer, if any.
    public mutating func reattached(state newState: TerminalSizingState?, selfParticipantID selfID: String?) {
        attachment = .attached
        if let newState {
            state = newState
        }
        if let selfID { selfParticipantID = selfID }
        viewportReassertGeneration &+= 1
    }

    /// Marks a network recovery that finished without a size state (an older
    /// host that does not publish one).
    public mutating func recoveredFromNetwork() {
        if attachment == .reconnecting { attachment = .attached }
    }
}

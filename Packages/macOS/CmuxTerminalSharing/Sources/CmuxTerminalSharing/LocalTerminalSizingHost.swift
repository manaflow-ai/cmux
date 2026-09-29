import CmuxTerminalSizing

/// The sizing host of one local Mac terminal.
///
/// Wraps ``TerminalSizingEngine`` with the Mac-specific rules: the Mac pane is
/// always attached as participant ``macParticipantID``; each paired phone is
/// `mobile:<client_id>`; a phone that someone disconnected stays out (its
/// reports are refused) until it reattaches. Pure and synchronous, so the
/// controller that owns the Ghostty surface decides when to apply.
public struct LocalTerminalSizingHost: Sendable {
    /// The engine; its `state` is what every viewer sees.
    public private(set) var engine: TerminalSizingEngine
    /// The participant id of the Mac pane itself.
    public let macParticipantID: String
    /// Phones disconnected by someone, keyed by participant id.
    public private(set) var detachedPhones: [String: TerminalSharingDetachment] = [:]
    /// Phones that reattached as viewers; their next attach has `counts_override: false`.
    private var viewerOnNextAttach: Set<String> = []

    /// The participant id of a paired phone.
    ///
    /// - Parameter clientID: the phone's mobile `client_id`.
    /// - Returns: `mobile:<client_id>`.
    public static func phoneParticipantID(clientID: String) -> String { "mobile:\(clientID)" }

    /// Creates the host with the Mac pane attached.
    ///
    /// - Parameters:
    ///   - macParticipant: the Mac pane; its viewport is the pane's own grid.
    ///   - initialSize: the grid before anyone else reports, normally the PTY's size.
    ///   - policy: the effective policy.
    public init(
        macParticipant: TerminalSizingParticipant,
        initialSize: TerminalGridSize,
        policy: TerminalSizingPolicy = .fitEveryone
    ) {
        macParticipantID = macParticipant.id
        engine = TerminalSizingEngine(initialSize: initialSize, policy: policy)
        engine.attach(macParticipant)
    }

    /// The published state.
    public var state: TerminalSizingState { engine.state }

    /// The Mac pane's own grid, as last reported.
    public var macViewport: TerminalGridSize? {
        state.participant(macParticipantID)?.participant.viewport
    }

    /// Attached participants other than the Mac pane.
    public var phoneParticipantIDs: [String] {
        engine.participantIDs.filter { $0 != macParticipantID }
    }

    /// What to apply to the Ghostty surface: nothing extra when the grid is the
    /// Mac pane's own grid, otherwise a pin to the decided grid.
    public var applyTarget: TerminalSizingApplyTarget {
        let size = state.size
        if let macViewport, macViewport == size { return .uncapped }
        return .grid(size)
    }

    /// Whether the participant is disconnected and must not report or type.
    ///
    /// - Parameter id: a participant id.
    /// - Returns: `true` while a disconnect is in force.
    public func isDetached(_ id: String) -> Bool { detachedPhones[id] != nil }

    // MARK: Mutations. Each returns true when the published state changed.

    /// Records the Mac pane's current grid.
    @discardableResult
    public mutating func updateMacViewport(_ viewport: TerminalGridSize) -> Bool {
        engine.report(macParticipantID, viewport: viewport)
    }

    /// Makes the attached phone set equal `phones`: attaches new ones (attach is
    /// activity), reports changed viewports, and detaches the rest. Detached
    /// phones in the list are ignored. Identity and counts overrides of phones
    /// already attached are kept.
    ///
    /// - Parameter phones: every phone currently reporting, with viewports.
    /// - Returns: whether the published state changed.
    @discardableResult
    public mutating func syncPhones(_ phones: [TerminalSizingParticipant]) -> Bool {
        var changed = false
        var wanted = Set<String>()
        for var phone in phones where phone.id != macParticipantID && !isDetached(phone.id) {
            wanted.insert(phone.id)
            if let existing = state.participant(phone.id)?.participant {
                if let viewport = phone.viewport, viewport != existing.viewport {
                    changed = engine.report(phone.id, viewport: viewport) || changed
                }
            } else {
                phone.countsOverride = viewerOnNextAttach.remove(phone.id) != nil ? false : phone.countsOverride
                changed = engine.attach(phone) || changed
            }
        }
        for id in phoneParticipantIDs where !wanted.contains(id) {
            changed = engine.detach(id) || changed
        }
        return changed
    }

    /// Explicit input or focus from a participant.
    @discardableResult
    public mutating func noteActivity(_ id: String) -> Bool {
        guard !isDetached(id) else { return false }
        return engine.noteActivity(id)
    }

    /// Sets the effective policy.
    @discardableResult
    public mutating func setPolicy(_ policy: TerminalSizingPolicy) -> Bool {
        engine.setPolicy(policy)
    }

    /// Sets or clears a participant's counts override.
    @discardableResult
    public mutating func setCountsOverride(_ id: String, _ value: Bool?) -> Bool {
        engine.setCountsOverride(id, value)
    }

    /// Disconnects a phone. It stays out until ``reattach(_:asViewer:)``.
    /// The Mac pane itself cannot be disconnected from its own host.
    ///
    /// - Parameters:
    ///   - id: the phone's participant id.
    ///   - detachment: the reason and time to report to the phone.
    /// - Returns: whether the participant was attached and is now detached.
    @discardableResult
    public mutating func disconnect(_ id: String, detachment: TerminalSharingDetachment) -> Bool {
        guard id != macParticipantID, state.participant(id) != nil else { return false }
        detachedPhones[id] = detachment
        viewerOnNextAttach.remove(id)
        engine.detach(id)
        return true
    }

    /// Lifts a disconnect so the phone's next report attaches it again.
    ///
    /// - Parameters:
    ///   - id: the phone's participant id.
    ///   - asViewer: attach with `counts_override: false`.
    public mutating func reattach(_ id: String, asViewer: Bool) {
        detachedPhones[id] = nil
        if asViewer { viewerOnNextAttach.insert(id) } else { viewerOnNextAttach.remove(id) }
    }

    /// Forgets a phone whose connection closed, including a pending disconnect.
    @discardableResult
    public mutating func forgetPhone(_ id: String) -> Bool {
        detachedPhones[id] = nil
        viewerOnNextAttach.remove(id)
        return engine.detach(id)
    }
}

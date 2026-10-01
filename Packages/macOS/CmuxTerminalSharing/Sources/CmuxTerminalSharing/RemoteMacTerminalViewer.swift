import CmuxTerminalSizing
import Foundation

/// A Mac viewing another Mac's local terminal (Devices), as one participant
/// of the host Mac's ``LocalTerminalSizingHost``.
///
/// The viewing Mac is a mobile RPC client of the host, like a paired phone:
/// the host names it `mobile:<client_id>` and the same shared model and
/// entrypoints apply (counts rules, disconnect, reattach, size panel). It
/// reports `device_kind: mac` with its own device name and ``TerminalSharingIdentity/deviceID``,
/// so its priority key never collides with the host Mac's or a phone's.
/// This value holds no transport; the mirror session sends what it returns.
public struct RemoteMacTerminalViewer: Sendable {
    /// The mobile client id the host keys this viewer's reports by.
    public let clientID: String
    /// This Mac's identity.
    public let identity: TerminalSharingIdentity
    /// The pane's own grid, as last measured.
    public private(set) var viewport: TerminalGridSize?
    /// The viewport generation of the latest report.
    public private(set) var generation: UInt64 = 0
    /// The host's latest size state.
    public private(set) var state: TerminalSizingState?
    /// This viewer's participant id in ``state``.
    public private(set) var selfParticipantID: String?
    /// Set while someone disconnected this viewer.
    public private(set) var detachment: TerminalSharingDetachment?

    /// Creates a viewer.
    ///
    /// - Parameters:
    ///   - clientID: the mobile client id of the device link.
    ///   - identity: this Mac's identity.
    public init(clientID: String, identity: TerminalSharingIdentity) {
        self.clientID = clientID
        self.identity = identity
    }

    /// What this Mac's pane draws, once the host published a state.
    public var snapshot: TerminalSharingSnapshot? {
        state.map {
            TerminalSharingSnapshot(state: $0, selfParticipantID: selfParticipantID, detachment: detachment, isCloud: false)
        }
    }

    // MARK: Requests

    /// The viewport fields a `mobile.terminal.replay` carries, so the host
    /// registers this Mac before it captures. Empty until the pane measured.
    public func replayParams() -> [String: Any] {
        guard let viewport else { return [:] }
        return reportFields(viewport)
    }

    /// The current `mobile.terminal.viewport` report (sticky on the host),
    /// or `nil` before the pane measured or while detached.
    public func viewportParams() -> [String: Any]? {
        guard detachment == nil, let viewport else { return nil }
        return reportFields(viewport)
    }

    /// Records the pane's grid.
    ///
    /// - Parameter viewport: the pane's natural grid.
    /// - Returns: the `mobile.terminal.viewport` report to send, or `nil`
    ///   when the grid did not change or this viewer is detached.
    public mutating func paneResized(_ viewport: TerminalGridSize) -> [String: Any]? {
        let viewport = viewport.clamped
        guard viewport != self.viewport else { return nil }
        self.viewport = viewport
        generation += 1
        return viewportParams()
    }

    /// A report that changes only `counts_override` (`nil` restores the
    /// automatic rule). Keeps the generation: the grid did not change.
    public func countsParams(_ value: Bool?) -> [String: Any]? {
        guard var params = viewportParams() else { return nil }
        params["counts_override"] = value.map { $0 as Any } ?? NSNull()
        return params
    }

    /// `mobile.terminal.reattach` fields after a disconnect.
    public func reattachParams(asViewer: Bool) -> [String: Any] {
        var params = replayParams()
        params["client_id"] = clientID
        params["as_viewer"] = asViewer
        params["device_kind"] = TerminalDeviceKind.mac.rawValue
        return params
    }

    /// The `mobile.terminal.viewport` clear sent when this pane stops
    /// mirroring, so it stops counting at once.
    public func clearParams() -> [String: Any] {
        ["client_id": clientID, "clear": true, "viewport_generation": Int(clamping: generation + 1)]
    }

    private func reportFields(_ viewport: TerminalGridSize) -> [String: Any] {
        var params: [String: Any] = [
            "client_id": clientID,
            "viewport_columns": viewport.cols,
            "viewport_rows": viewport.rows,
            "viewport_generation": Int(clamping: generation),
            "device_kind": TerminalDeviceKind.mac.rawValue,
        ]
        if let name = identity.deviceName { params["device_name"] = name }
        if let deviceID = identity.deviceID { params["device_id"] = deviceID }
        return params
    }

    // MARK: Host events

    /// Accepts a size state from a replay answer or a `mobile.terminal.size_state` push.
    ///
    /// - Returns: whether it is new (a newer generation or the first state).
    @discardableResult
    public mutating func receive(_ next: TerminalSizingState, selfParticipantID: String?) -> Bool {
        if let state, next.generation < state.generation { return false }
        let changed = state != next || self.selfParticipantID != selfParticipantID
        state = next
        self.selfParticipantID = selfParticipantID
        return changed
    }

    /// Someone disconnected this viewer (`mobile.terminal.detached`).
    public mutating func detached(_ detachment: TerminalSharingDetachment) {
        self.detachment = detachment
    }

    /// The host accepted a reattach.
    public mutating func reattached() {
        detachment = nil
    }
}

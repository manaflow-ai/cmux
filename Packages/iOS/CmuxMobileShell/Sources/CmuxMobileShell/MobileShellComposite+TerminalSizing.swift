internal import CmuxMobileDiagnostics
internal import CmuxMobileRPC
public import CmuxMobileShellModel
public import CmuxTerminalSizing
internal import Foundation
internal import OSLog

nonisolated private let terminalSizingLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

/// Shared terminal sizing: the per-surface size state, detach handling, and
/// the size sheet actions. Contract: `docs/shared-terminal-sizing.md`.
extension MobileShellComposite {
    static let terminalSizeStateTopic = "mobile.terminal.size_state"
    static let terminalDetachedTopic = "mobile.terminal.detached"

    // MARK: Reads

    /// The sizing state of one terminal, or `nil` before the host published one.
    /// - Parameter surfaceID: The terminal surface id.
    public func terminalSizing(for surfaceID: String) -> MobileTerminalSizingSurface? {
        terminalSizingBySurfaceID[surfaceID]
    }

    /// The bounds and size-sheet facts for one terminal, or `nil` when the
    /// host has not published a size state.
    /// - Parameter surfaceID: The terminal surface id.
    public func terminalSizingPresentation(for surfaceID: String) -> MobileTerminalSizingPresentation? {
        guard let surface = terminalSizingBySurfaceID[surfaceID],
              let state = surface.state else { return nil }
        let local = reportedTerminalViewportSizesBySurfaceID[surfaceID]
            .map { TerminalGridSize(cols: $0.columns, rows: $0.rows) }
        return MobileTerminalSizingPresentation(
            state: state,
            selfParticipantID: surface.selfParticipantID ?? defaultTerminalParticipantID,
            localViewport: local
        )
    }

    /// Whether viewport, input and replay may flow for a terminal. `false`
    /// only while the host detached this phone from it.
    /// - Parameter surfaceID: The terminal surface id.
    public func terminalAllowsTraffic(surfaceID: String) -> Bool {
        terminalSizingBySurfaceID[surfaceID]?.attachment.allowsTerminalTraffic ?? true
    }

    /// The participant id the contract assigns this phone: `mobile:<client_id>`.
    var defaultTerminalParticipantID: String { "mobile:\(clientID)" }

    /// `device_kind` and `device_name` for viewport reports.
    var terminalDeviceIdentity: MobileTerminalDeviceIdentity { MobileTerminalDeviceIdentity.current() }

    // MARK: Events

    func handleTerminalSizeStateEvent(_ event: MobileEventEnvelope) {
        guard let json = event.payloadJSON,
              let payload = try? MobileTerminalSizeStateEvent.decode(json) else {
            terminalSizingLog.error("size_state push decode failed")
            return
        }
        applyTerminalSizeState(
            payload.state,
            selfParticipantID: payload.selfParticipantID,
            surfaceID: payload.surfaceID
        )
    }

    func handleTerminalDetachedEvent(_ event: MobileEventEnvelope) {
        guard let json = event.payloadJSON,
              let payload = try? MobileTerminalDetachedEvent.decode(json) else {
            terminalSizingLog.error("detached push decode failed")
            return
        }
        applyTerminalDetached(payload)
    }

    /// Applies a size state from any source (push, replay, reattach).
    func applyTerminalSizeState(
        _ state: TerminalSizingState,
        selfParticipantID: String?,
        surfaceID: String
    ) {
        var surface = terminalSizingBySurfaceID[surfaceID] ?? MobileTerminalSizingSurface()
        let effective = effectiveViewportSizesBySurfaceID[surfaceID]
            .map { TerminalGridSize(cols: $0.columns, rows: $0.rows) }
        _ = surface.applySizeState(state, selfParticipantID: selfParticipantID, effectiveGrid: effective)
        // `.reassertViewport` is carried by `viewportReassertGeneration`,
        // which the mounted surface observes.
        terminalSizingBySurfaceID[surfaceID] = surface
    }

    /// Applies a `detached` push.
    func applyTerminalDetached(_ event: MobileTerminalDetachedEvent) {
        var surface = terminalSizingBySurfaceID[event.surfaceID] ?? MobileTerminalSizingSurface()
        let effect = surface.applyDetached(reason: event.reason, at: event.at ?? Date())
        terminalSizingBySurfaceID[event.surfaceID] = surface
        MobileDebugLog.anchormux(
            "terminal.sizing.detached surface=\(event.surfaceID) reason=\(event.reason.wireValue)"
        )
        switch effect {
        case .reconnect:
            // Network drop: the existing recovery path replays and re-reports.
            if hasTerminalOutputSink(surfaceID: event.surfaceID) {
                terminalOutputNeedsReplay(surfaceID: event.surfaceID)
            }
        case .none, .reassertViewport:
            break
        }
    }

    /// Records the sizing fields of a replay result.
    func applyTerminalReplaySizing(_ response: MobileTerminalReplayResponse, surfaceID: String) {
        if let state = response.sizeState {
            applyTerminalSizeState(state, selfParticipantID: response.selfParticipantID, surfaceID: surfaceID)
        } else if var surface = terminalSizingBySurfaceID[surfaceID] {
            surface.recoveredFromNetwork()
            terminalSizingBySurfaceID[surfaceID] = surface
        }
    }

    // MARK: Actions

    /// Reattaches a detached terminal with `mobile.terminal.reattach`.
    /// - Parameters:
    ///   - surfaceID: The terminal surface id.
    ///   - asViewer: `true` reattaches without resizing (`counts_override: false`).
    /// - Returns: `true` when the host accepted the reattach.
    @discardableResult
    public func reattachTerminal(surfaceID: String, asViewer: Bool) async -> Bool {
        guard let workspaceID = workspaceID(forTerminalID: surfaceID),
              let client = remoteClient else { return false }
        var params: [String: Any] = [
            "workspace_id": remoteWorkspaceID(for: workspaceID).rawValue,
            "surface_id": surfaceID,
            "client_id": clientID,
            "as_viewer": asViewer,
        ]
        let identity = terminalDeviceIdentity
        params["device_kind"] = identity.kind.rawValue
        params["device_name"] = identity.name
        if let viewport = reportedTerminalViewportSizesBySurfaceID[surfaceID] {
            params["viewport_columns"] = viewport.columns
            params["viewport_rows"] = viewport.rows
        }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.terminal.reattach",
                params: params
            )
            let data = try await client.sendRequest(request)
            guard remoteClient === client else { return false }
            let sizing = MobileTerminalReplaySizing.decodeIfPresent(data)
            var surface = terminalSizingBySurfaceID[surfaceID] ?? MobileTerminalSizingSurface()
            surface.reattached(state: sizing?.sizeState, selfParticipantID: sizing?.selfParticipantID)
            terminalSizingBySurfaceID[surfaceID] = surface
            // The reattach answer carries a replay, but the replay pipeline
            // owns barriers and sequencing; request the normal cold-attach
            // replay instead of feeding this payload around it.
            if hasTerminalOutputSink(surfaceID: surfaceID) {
                requestColdAttachTerminalReplay(surfaceID: surfaceID)
            }
            return true
        } catch {
            terminalSizingLog.error(
                "reattach failed surface=\(surfaceID, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            _ = disconnectForAuthorizationFailureIfNeeded(error)
            return false
        }
    }

    /// Sets the terminal's sizing policy with `mobile.terminal.size_policy.set`.
    /// - Parameters:
    ///   - policy: The new policy.
    ///   - surfaceID: The terminal surface id.
    /// - Returns: `true` when the host accepted the policy.
    @discardableResult
    public func setTerminalSizePolicy(_ policy: TerminalSizingPolicy, surfaceID: String) async -> Bool {
        guard let policyObject = try? JSONSerialization.jsonObject(
            with: JSONEncoder().encode(policy)
        ) else { return false }
        return await sendTerminalSizingRequest(
            method: "mobile.terminal.size_policy.set",
            surfaceID: surfaceID,
            extra: ["policy": policyObject]
        )
    }

    /// Disconnects another participant with `mobile.terminal.participant.disconnect`.
    /// - Parameters:
    ///   - participantID: The host's participant id.
    ///   - surfaceID: The terminal surface id.
    /// - Returns: `true` when the host accepted the disconnect.
    @discardableResult
    public func disconnectTerminalParticipant(_ participantID: String, surfaceID: String) async -> Bool {
        await sendTerminalSizingRequest(
            method: "mobile.terminal.participant.disconnect",
            surfaceID: surfaceID,
            extra: ["participant_id": participantID]
        )
    }

    /// Disconnects every other participant, one request each.
    /// - Parameter surfaceID: The terminal surface id.
    /// - Returns: `true` when every disconnect succeeded.
    @discardableResult
    public func disconnectOtherTerminalParticipants(surfaceID: String) async -> Bool {
        guard let presentation = terminalSizingPresentation(for: surfaceID) else { return false }
        var allSucceeded = true
        for participant in presentation.otherParticipants {
            let succeeded = await disconnectTerminalParticipant(participant.id, surfaceID: surfaceID)
            allSucceeded = allSucceeded && succeeded
        }
        return allSucceeded
    }

    /// Sets or clears whether this phone counts toward size, through a
    /// `mobile.terminal.viewport` report that carries `counts_override`.
    /// - Parameters:
    ///   - counts: `true`/`false` sets the override; `nil` restores the automatic rule.
    ///   - surfaceID: The terminal surface id.
    /// - Returns: `true` when the host accepted the report.
    @discardableResult
    public func setTerminalCountsOverride(_ counts: Bool?, surfaceID: String) async -> Bool {
        guard terminalAllowsTraffic(surfaceID: surfaceID),
              let workspaceID = workspaceID(forTerminalID: surfaceID),
              let viewport = reportedTerminalViewportSizesBySurfaceID[surfaceID],
              let client = remoteClient else { return false }
        let sequenceKey = MobileTerminalViewportSequenceKey(
            ownerKey: foregroundMacKey,
            surfaceID: surfaceID
        )
        // Reuse the current generation: the grid is unchanged, so this report
        // must not supersede an in-flight geometry report.
        let generation = viewportReportGenerationsBySequenceKey[sequenceKey] ?? 0
        let params = MobileTerminalViewportParameters(
            clientID: clientID,
            identity: terminalDeviceIdentity
        ).report(
            workspaceID: remoteWorkspaceID(for: workspaceID).rawValue,
            surfaceID: surfaceID,
            viewport: viewport,
            generation: generation,
            countsOverride: counts.map { .set($0) } ?? .clear
        )
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.terminal.viewport",
                params: params
            )
            _ = try await client.sendRequest(request)
            return remoteClient === client
        } catch {
            terminalSizingLog.error(
                "counts override failed surface=\(surfaceID, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            _ = disconnectForAuthorizationFailureIfNeeded(error)
            return false
        }
    }

    private func sendTerminalSizingRequest(
        method: String,
        surfaceID: String,
        extra: [String: Any]
    ) async -> Bool {
        guard let workspaceID = workspaceID(forTerminalID: surfaceID),
              let client = remoteClient else { return false }
        var params: [String: Any] = [
            "workspace_id": remoteWorkspaceID(for: workspaceID).rawValue,
            "surface_id": surfaceID,
            "client_id": clientID,
        ]
        params.merge(extra) { _, new in new }
        do {
            let request = try MobileCoreRPCClient.requestData(method: method, params: params)
            _ = try await client.sendRequest(request)
            return remoteClient === client
        } catch {
            terminalSizingLog.error(
                "\(method, privacy: .public) failed surface=\(surfaceID, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            _ = disconnectForAuthorizationFailureIfNeeded(error)
            return false
        }
    }
}

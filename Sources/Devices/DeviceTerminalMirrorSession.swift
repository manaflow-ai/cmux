import CMUXMobileCore
import CmuxMobileRPC
import CmuxTerminal
import CmuxTerminalSharing
import CmuxTerminalSizing
import Foundation
import OSLog

nonisolated private let deviceMirrorLog = Logger(subsystem: "dev.cmux", category: "device-terminal-mirror")

/// Owns one local projection of a terminal running on another Mac.
///
/// The remote Mac's Ghostty surface stays the PTY owner. This session feeds
/// that surface's raw PTY bytes (`terminal.bytes`, chained by sequence from a
/// render-grid replay on attach) into a local manual-mirror ``TerminalSurface``,
/// sends local keystrokes back as `mobile.terminal.input`. The source Mac owns
/// the terminal grid: mirrors follow its replay and resize events.
///
/// With a sizing identity this Mac is a participant of the source Mac's
/// shared sizing (docs/shared-terminal-sizing.md), exactly like a paired
/// phone: it reports its pane's grid as `device_kind: mac`, counts by the
/// same rules, shows the bounds and chip in its pane, and can be
/// disconnected and reattached through the same size panel actions.
@MainActor
final class DeviceTerminalMirrorSession {
    enum Phase: Equatable {
        case idle
        case attaching
        case attached
        case detached
        case stopped
    }

    private let isConnected: @MainActor @Sendable () -> Bool
    private let events: DeviceLinkTerminalEvents
    private let requestData: @MainActor @Sendable (String, [String: Any]) async throws -> Data
    let remoteWorkspaceID: String
    let remoteSurfaceID: UUID
    let inputRouter: DeviceTerminalInputRouter
    let attachment: DeviceTerminalAttachmentStatus
    private(set) var phase: Phase = .idle {
        didSet {
            inputRouter.setEnabled(phase == .attached)
            attachment.update(connected: phase == .attached, connecting: phase == .attaching)
        }
    }
    private(set) var assignedGrid: (columns: Int, rows: Int)?
    var onAttached: (@MainActor () -> Void)?
    /// The reserved pane's early input, held until an attach sticks. Losing
    /// the link discards it, since a restarted Mac can restore a terminal
    /// under the same surface ID with a new shell, and so does stopping the
    /// session, so a replacement owner never inherits it.
    private var adoptedRelay: CloudOptimisticInputRelay?

    private weak var surface: TerminalSurface?
    private var eventTask: Task<Void, Never>?
    private var attachTask: Task<Void, Never>?
    private var expectedSequence: UInt64?
    private var replayNeeded = false
    private var attachingBytes: [(sequence: UInt64?, data: Data)] = []
    private var attachingByteCount = 0
    /// This Mac as a shared-sizing participant of the source Mac, when it has
    /// an identity (the production path; tests may omit it).
    private(set) var viewer: RemoteMacTerminalViewer?
    /// The local surface id this session published sharing state under.
    private var sharingSurfaceID: UUID?
    /// Consecutive `viewport_transition` answers, bounded so a host that never
    /// settles cannot spin the attach loop.
    private var viewportTransitionRetries = 0

    convenience init(link: DeviceLink, remoteWorkspaceID: String, remoteSurfaceID: UUID) {
        self.init(
            remoteWorkspaceID: remoteWorkspaceID, remoteSurfaceID: remoteSurfaceID,
            events: link.terminalEvents,
            isConnected: { link.isConnected },
            requestData: { method, params in try await link.requestData(method, params: params) },
            viewer: RemoteMacTerminalViewer(
                clientID: link.clientID,
                identity: TerminalController.shared.localSizingIdentity()
            )
        )
    }

    init(
        remoteWorkspaceID: String,
        remoteSurfaceID: UUID,
        events: DeviceLinkTerminalEvents,
        isConnected: @escaping @MainActor @Sendable () -> Bool,
        requestData: @escaping @MainActor @Sendable (String, [String: Any]) async throws -> Data,
        viewer: RemoteMacTerminalViewer? = nil
    ) {
        self.remoteWorkspaceID = remoteWorkspaceID
        self.remoteSurfaceID = remoteSurfaceID
        self.events = events
        self.isConnected = isConnected
        self.requestData = requestData
        self.viewer = viewer
        let attachment = DeviceTerminalAttachmentStatus()
        self.attachment = attachment
        let clientID = viewer?.clientID
        inputRouter = DeviceTerminalInputRouter(
            send: { @MainActor data in
                guard attachment.isConnected, isConnected() else { throw DeviceLinkError.notConnected }
                guard let text = String(data: data, encoding: .utf8) else { throw DeviceTerminalInputRouter.InputError.invalidEncoding }
                var input: [String: Any] = [
                    "workspace_id": remoteWorkspaceID,
                    "surface_id": remoteSurfaceID.uuidString,
                    "text": text
                ]
                // The client id makes input sizing activity on the host and
                // lets the host refuse it while this Mac is disconnected.
                if let clientID { input["client_id"] = clientID }
                let response = try await requestData("mobile.terminal.input", input)
                _ = try Self.responseObject(response, method: "mobile.terminal.input")
            },
            onFailure: { error in
                deviceMirrorLog.error("device terminal input failed: \(String(describing: error), privacy: .private)")
            }
        )
    }

    private static func responseObject(_ data: Data, method: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeviceLinkError.malformedResponse(method)
        }
        return object
    }

    private var surfaceParams: [String: Any] {
        ["workspace_id": remoteWorkspaceID, "surface_id": remoteSurfaceID.uuidString]
    }

    /// Applies the source grid to the local renderer. A participant also
    /// reports the pane's own grid whenever it changes.
    func bind(surface: TerminalSurface) {
        self.surface = surface
        if let assigned = assignedGrid {
            surface.setAssignedGrid(columns: assigned.columns, rows: assigned.rows)
        }
        guard viewer != nil else { return }
        sharingSurfaceID = surface.id
        // While the grid is pinned to the source Mac's, a pane resize changes
        // no Ghostty size, so it arrives here.
        surface.onNaturalGridInputsChanged = { [weak self] in
            // Hop out of the in-progress updateSize before re-reporting.
            Task { @MainActor [weak self] in self?.paneGridChanged() }
        }
        measurePaneGrid()
    }

    func start() {
        guard phase == .idle else { return }
        phase = .attaching
        startEventConsumer()
        scheduleAttach()
    }

    func stop() {
        guard phase != .stopped else { return }
        phase = .stopped
        attachingBytes.removeAll()
        attachingByteCount = 0
        attachTask?.cancel()
        attachTask = nil
        eventTask?.cancel()
        eventTask = nil
        inputRouter.invalidate()
        onAttached = nil
        adoptedRelay?.discard()
        adoptedRelay = nil
        leaveSharing()
        surface?.clearAssignedGrid()
        surface = nil
    }

    func retry() {
        guard phase != .stopped else { return }
        scheduleAttach()
    }

    /// Takes over a reserved pane's input. What was typed before an attach
    /// first sticks, including while a replay failed on a live link, belongs
    /// to this remote surface and is delivered in order once one does. If the
    /// link drops first, that input is discarded rather than sent to whatever
    /// shell the Mac has when it comes back. After an attach the router drops
    /// input typed while detached, as it does for panes it created itself, and
    /// stopping the session discards anything still held.
    func adopt(_ relay: CloudOptimisticInputRelay) {
        adoptedRelay = relay
        onAttached = { [weak self] in
            guard let self else { return }
            relay.attach(self.inputRouter)
        }
    }

    // MARK: - Attach and bytes

    private func startEventConsumer() {
        let stream = events.stream(surfaceID: remoteSurfaceID)
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self, self.phase != .stopped else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: DeviceTerminalEvent) {
        switch event {
        case .bytes(let sequence, let data):
            if phase == .attaching {
                guard sequence != nil, attachingBytes.count < 512, attachingByteCount + data.count <= 256 * 1_024 else {
                    replayNeeded = true
                    attachingBytes.removeAll()
                    attachingByteCount = 0
                    return
                }
                attachingBytes.append((sequence, data))
                attachingByteCount += data.count
                return
            }
            guard phase == .attached, let surface else { return }
            guard let sequence, let expected = expectedSequence else {
                surface.processRemoteOutput(data)
                return
            }
            let end = sequence &+ UInt64(data.count)
            if end <= expected { return }
            if sequence > expected {
                // A dropped chunk: the byte stream is not self-healing, so
                // re-anchor on a fresh replay instead of rendering a hole.
                scheduleAttach()
                return
            }
            let offset = Int(expected - sequence)
            surface.processRemoteOutput(offset == 0 ? data : Data(data.dropFirst(offset)))
            expectedSequence = end
        case .updated(let columns, let rows):
            guard let columns, let rows, columns > 0, rows > 0 else { return }
            if let assigned = assignedGrid, assigned.columns == columns, assigned.rows == rows { return }
            // Repaint at the geometry the source Mac reports.
            pin(columns: columns, rows: rows)
            scheduleAttach()
        case .resyncRequired:
            if isConnected() {
                scheduleAttach()
            } else {
                linkDropped()
            }
        case .linkReconnected:
            scheduleAttach()
        case .linkLost:
            linkDropped()
        case let .sizeState(state, selfParticipantID):
            guard viewer?.receive(state, selfParticipantID: selfParticipantID) == true else { return }
            publishSharing()
        case let .sharingDetached(reason, at):
            guard viewer != nil else { return }
            viewer?.detached(TerminalSharingDetachment(reason: reason, at: at ?? Date()))
            publishSharing()
        }
    }

    /// Detaches and drops the reserved pane's held input: the next attach that
    /// sticks resumes forwarding from what is typed after it.
    private func linkDropped() {
        adoptedRelay?.discard()
        if phase == .attached || phase == .attaching { phase = .detached }
    }

    /// Single-flight replay of the source screen, followed by sequenced live bytes.
    private func scheduleAttach() {
        guard phase != .stopped, attachTask == nil else {
            replayNeeded = attachTask != nil
            return
        }
        attachTask = Task { [weak self] in
            guard let self else { return }
            await self.attach()
            self.attachTask = nil
            if self.replayNeeded {
                self.replayNeeded = false
                self.scheduleAttach()
            }
        }
    }

    private func attach() async {
        guard phase != .stopped, isConnected() else {
            if phase != .stopped {
                adoptedRelay?.discard()
                phase = .detached
            }
            return
        }
        phase = .attaching
        attachingBytes.removeAll(keepingCapacity: true)
        attachingByteCount = 0
        guard !Task.isCancelled, phase != .stopped else { return }
        do {
            var params = surfaceParams
            if let viewer, viewer.detachment == nil {
                // Register this Mac with its pane grid before the host captures.
                params.merge(viewer.replayParams()) { _, new in new }
            }
            let response = try await requestData("mobile.terminal.replay", params)
            let replay = try await Self.decodeReplay(response)
            guard !Task.isCancelled, phase == .attaching, isConnected() else { return }
            viewportTransitionRetries = 0
            receiveReplaySizing(response)
            if let columns = replay.columns, let rows = replay.rows { pin(columns: columns, rows: rows) }
            surface?.processRemoteOutput(replay.bytes)
            expectedSequence = replay.sequence
            phase = .attached
            let buffered = attachingBytes
            attachingBytes.removeAll(keepingCapacity: true)
            attachingByteCount = 0
            // Discard bytes already covered by the replay, then apply the
            // remaining contiguous tail through the normal sequence check.
            for chunk in buffered { handle(.bytes(sequence: chunk.sequence, data: chunk.data)) }
            // A replay queued meanwhile re-enters `.attaching` at once, which
            // drops input the router has not sent yet. Hand over held input
            // only on the attach that sticks.
            if !replayNeeded { onAttached?() }
        } catch DeviceLinkError.notConnected {
            guard phase != .stopped else { return }
            adoptedRelay?.discard()
            phase = .detached
        } catch {
            guard !Task.isCancelled, phase != .stopped else { return }
            if Self.isViewportTransition(error), viewportTransitionRetries < 3 {
                // The host is applying this Mac's grid; the next replay
                // captures the settled grid.
                viewportTransitionRetries += 1
                replayNeeded = true
                return
            }
            deviceMirrorLog.error("device terminal replay failed: \(String(describing: error), privacy: .private)")
            phase = .detached
        }
    }

    private static func isViewportTransition(_ error: Error) -> Bool {
        String(describing: error).contains("viewport_transition")
    }

    private struct Replay: Sendable {
        let bytes: Data
        let columns: Int?
        let rows: Int?
        let sequence: UInt64?
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated private static func decodeReplay(_ data: Data) async throws -> Replay {
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeviceLinkError.malformedResponse("mobile.terminal.replay")
        }
        let sequence = (response["seq"] as? NSNumber)?.uint64Value
        if let raw = response["render_grid"] {
            let frame = try MobileTerminalRenderGridFrame.decodeJSONObject(raw)
            return Replay(
                bytes: MobileTerminalRenderGridReplay(frame).patchBytes(),
                columns: frame.columns > 0 ? frame.columns : nil,
                rows: frame.rows > 0 ? frame.rows : nil,
                sequence: sequence
            )
        } else {
            let columns = (response["columns"] as? NSNumber)?.intValue
            let rows = (response["rows"] as? NSNumber)?.intValue
            var bytes = replayReset
            if let encoded = response["snapshot_data_b64"] as? String, let data = Data(base64Encoded: encoded) {
                bytes.append(data)
            } else if let encoded = response["data_b64"] as? String, let data = Data(base64Encoded: encoded) {
                bytes.append(data)
            }
            return Replay(bytes: bytes, columns: columns.flatMap { $0 > 0 ? $0 : nil }, rows: rows.flatMap { $0 > 0 ? $0 : nil }, sequence: sequence)
        }
    }

    /// `ESC c` (full reset) then `CSI 3 J` (drop scrollback): the replay is a
    /// replacement, so nothing from before it may survive.
    nonisolated private static let replayReset = Data([0x1B, 0x63, 0x1B, 0x5B, 0x33, 0x4A])

    // MARK: - Shared sizing (this Mac as a participant of the source Mac)

    @discardableResult
    private func measurePaneGrid() -> [String: Any]? {
        guard viewer != nil, let natural = surface?.naturalGridSize() else { return nil }
        return viewer?.paneResized(TerminalGridSize(cols: natural.columns, rows: natural.rows))
    }

    private func paneGridChanged() {
        guard phase != .stopped, let report = measurePaneGrid(), phase == .attached else { return }
        sendSizing("mobile.terminal.viewport", report)
    }

    private func receiveReplaySizing(_ response: Data) {
        guard viewer != nil else { return }
        if let sizing = MobileTerminalReplaySizing.decodeIfPresent(response), let state = sizing.sizeState {
            viewer?.receive(state, selfParticipantID: sizing.selfParticipantID)
        }
        publishSharing()
        // The replay's report expires on the host's TTL; the dedicated
        // report keeps this Mac attached for the link's lifetime.
        if let report = viewer?.viewportParams() { sendSizing("mobile.terminal.viewport", report) }
    }

    /// Sends one sizing request; failures only log, since the next size
    /// state or replay reconciles.
    private func sendSizing(_ method: String, _ params: [String: Any]) {
        var params = params
        params.merge(surfaceParams) { current, _ in current }
        let requestData = requestData
        Task { @MainActor in
            do {
                _ = try await requestData(method, params)
            } catch {
                deviceMirrorLog.error("device terminal \(method, privacy: .public) failed: \(String(describing: error), privacy: .private)")
            }
        }
    }

    private func publishSharing() {
        guard let viewer, let surfaceID = sharingSurfaceID else { return }
        let controller = TerminalController.shared
        controller.ensureTerminalSharingPresentation()
        controller.terminalSharing.register(self, surfaceID: surfaceID)
        controller.terminalSharing.publish(viewer.snapshot, surfaceID: surfaceID)
    }

    /// Stops counting at once instead of waiting for the link to close.
    private func leaveSharing() {
        guard let viewer else { return }
        if let surfaceID = sharingSurfaceID {
            TerminalController.shared.terminalSharing.unregister(self, surfaceID: surfaceID)
        }
        surface?.onNaturalGridInputsChanged = nil
        if viewer.viewport != nil, isConnected() { sendSizing("mobile.terminal.viewport", viewer.clearParams()) }
        sharingSurfaceID = nil
    }

    /// Pins only the mirror to the source grid; local resizing clips or letterboxes it.
    private func pin(columns: Int, rows: Int) {
        if let assigned = assignedGrid, assigned.columns == columns, assigned.rows == rows { return }
        assignedGrid = (columns, rows)
        surface?.setAssignedGrid(columns: columns, rows: rows)
    }
}

// MARK: - Size panel actions (TerminalSharingSurfaceControlling)

/// The size panel, tab accessory, context menu, palette and socket act on a
/// viewed Mac's terminal through the host's mobile RPC, as a phone does.
extension DeviceTerminalMirrorSession: TerminalSharingSurfaceControlling {
    func sharingSetPolicy(_ policy: TerminalSizingPolicy) -> Bool {
        guard viewer != nil else { return false }
        sendSizing("mobile.terminal.size_policy.set", ["policy": TerminalSizingWireCoder().jsonObject(policy)])
        return true
    }

    /// The host's mobile RPC sets the counts override of this viewer only.
    func sharingSetCountsOverride(participantID: String, value: Bool?) -> Bool {
        guard let viewer, participantID == viewer.selfParticipantID,
              let report = viewer.countsParams(value) else { return false }
        sendSizing("mobile.terminal.viewport", report)
        return true
    }

    /// The host names this Mac as the actor from its authenticated account
    /// and this client's reported device name.
    func sharingDisconnect(participantID: String, by: TerminalDetachActor?) -> Bool {
        guard let viewer else { return false }
        sendSizing("mobile.terminal.participant.disconnect", ["participant_id": participantID, "client_id": viewer.clientID])
        return true
    }

    /// Input already carries the client id, which the host records as
    /// activity; an explicit focus has no mobile RPC.
    func sharingNoteSelfActivity() {}

    func sharingReattach(asViewer: Bool) -> Bool {
        guard let viewer, viewer.detachment != nil else { return false }
        var params = viewer.reattachParams(asViewer: asViewer)
        params.merge(surfaceParams) { current, _ in current }
        let requestData = requestData
        Task { @MainActor [weak self] in
            do {
                _ = try await requestData("mobile.terminal.reattach", params)
                guard let self else { return }
                self.viewer?.reattached()
                self.publishSharing()
                // Re-anchor on a fresh replay: the host dropped this Mac's
                // viewport and input while it was disconnected.
                self.scheduleAttach()
            } catch {
                deviceMirrorLog.error("device terminal reattach failed: \(String(describing: error), privacy: .private)")
            }
        }
        return true
    }
}

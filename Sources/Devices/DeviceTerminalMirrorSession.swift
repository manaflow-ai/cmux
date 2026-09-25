import CMUXMobileCore
import CmuxTerminal
import Foundation
import OSLog

nonisolated private let deviceMirrorLog = Logger(subsystem: "dev.cmux", category: "device-terminal-mirror")

/// Owns one local projection of a terminal running on another Mac.
///
/// The remote Mac's Ghostty surface stays the PTY owner. This session feeds
/// that surface's raw PTY bytes (`terminal.bytes`, chained by sequence from a
/// render-grid replay on attach) into a local manual-mirror ``TerminalSurface``,
/// sends local keystrokes back as `mobile.terminal.input`. The source Mac owns
/// the terminal grid: mirrors follow its replay and resize events, without
/// reporting a viewport that could resize the original terminal.
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

    private weak var surface: TerminalSurface?
    private var eventTask: Task<Void, Never>?
    private var attachTask: Task<Void, Never>?
    private var expectedSequence: UInt64?
    private var replayNeeded = false
    private var attachingBytes: [(sequence: UInt64?, data: Data)] = []
    private var attachingByteCount = 0

    convenience init(link: DeviceLink, remoteWorkspaceID: String, remoteSurfaceID: UUID) {
        self.init(
            remoteWorkspaceID: remoteWorkspaceID, remoteSurfaceID: remoteSurfaceID,
            events: link.terminalEvents,
            isConnected: { link.isConnected },
            requestData: { method, params in try await link.requestData(method, params: params) }
        )
    }

    init(
        remoteWorkspaceID: String,
        remoteSurfaceID: UUID,
        events: DeviceLinkTerminalEvents,
        isConnected: @escaping @MainActor @Sendable () -> Bool,
        requestData: @escaping @MainActor @Sendable (String, [String: Any]) async throws -> Data
    ) {
        self.remoteWorkspaceID = remoteWorkspaceID
        self.remoteSurfaceID = remoteSurfaceID
        self.events = events
        self.isConnected = isConnected
        self.requestData = requestData
        let attachment = DeviceTerminalAttachmentStatus()
        self.attachment = attachment
        inputRouter = DeviceTerminalInputRouter(
            send: { @MainActor data in
                guard attachment.isConnected, isConnected() else { throw DeviceLinkError.notConnected }
                guard let text = String(data: data, encoding: .utf8) else { throw DeviceTerminalInputRouter.InputError.invalidEncoding }
                let input: [String: Any] = [
                    "workspace_id": remoteWorkspaceID,
                    "surface_id": remoteSurfaceID.uuidString,
                    "text": text
                ]
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

    /// Applies the source grid to the local renderer without claiming a host viewport.
    func bind(surface: TerminalSurface) {
        self.surface = surface
        if let assigned = assignedGrid {
            surface.setAssignedGrid(columns: assigned.columns, rows: assigned.rows)
        }
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
        surface?.clearAssignedGrid()
        surface = nil
    }

    func retry() {
        guard phase != .stopped else { return }
        scheduleAttach()
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
            } else if phase == .attached || phase == .attaching {
                phase = .detached
            }
        case .linkReconnected:
            scheduleAttach()
        case .linkLost:
            if phase == .attached || phase == .attaching { phase = .detached }
        }
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
            if phase != .stopped { phase = .detached }
            return
        }
        phase = .attaching
        attachingBytes.removeAll(keepingCapacity: true)
        attachingByteCount = 0
        guard !Task.isCancelled, phase != .stopped else { return }
        do {
            let response = try await requestData("mobile.terminal.replay", surfaceParams)
            let replay = try await Self.decodeReplay(response)
            guard !Task.isCancelled, phase == .attaching, isConnected() else { return }
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
        } catch DeviceLinkError.notConnected {
            guard phase != .stopped else { return }
            phase = .detached
        } catch {
            guard !Task.isCancelled, phase != .stopped else { return }
            deviceMirrorLog.error("device terminal replay failed: \(String(describing: error), privacy: .private)")
            phase = .detached
        }
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

    /// Pins only the mirror to the source grid; local resizing clips or letterboxes it.
    private func pin(columns: Int, rows: Int) {
        if let assigned = assignedGrid, assigned.columns == columns, assigned.rows == rows { return }
        assignedGrid = (columns, rows)
        surface?.setAssignedGrid(columns: columns, rows: rows)
    }
}

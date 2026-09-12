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
/// sends the local surface's keystrokes back as `mobile.terminal.input`, and
/// keeps both grids equal through the host's shared viewport: it reports the
/// local pane's grid, the host caps the terminal to the smallest attached
/// viewport (letterboxing its own pane), and the effective grid the host
/// answers with pins the local surface. Last writer wins; no roles.
@MainActor
final class DeviceTerminalMirrorSession {
    enum Phase: Equatable {
        case idle
        case attaching
        case attached
        case detached
        case stopped
    }

    let link: DeviceLink
    let remoteWorkspaceID: String
    let remoteSurfaceID: UUID
    let inputRouter: DeviceTerminalInputRouter
    private(set) var phase: Phase = .idle
    private(set) var assignedGrid: (columns: Int, rows: Int)?

    private weak var surface: TerminalSurface?
    private var eventTask: Task<Void, Never>?
    private var attachTask: Task<Void, Never>?
    private var viewportTask: Task<Void, Never>?
    private var expectedSequence: UInt64?
    private var viewportGeneration: UInt64 = 0
    private var reportedGrid: (columns: Int, rows: Int)?
    private var pendingGrid: (columns: Int, rows: Int)?
    private var isVisible = true
    private var replayNeeded = false
    private var attachingBytes: [(sequence: UInt64?, data: Data)] = []
    private var attachingByteCount = 0

    init(link: DeviceLink, remoteWorkspaceID: String, remoteSurfaceID: UUID) {
        self.link = link
        self.remoteWorkspaceID = remoteWorkspaceID
        self.remoteSurfaceID = remoteSurfaceID
        let params: [String: Any] = [
            "workspace_id": remoteWorkspaceID,
            "surface_id": remoteSurfaceID.uuidString,
        ]
        inputRouter = DeviceTerminalInputRouter(
            send: { data in
                guard let text = String(data: data, encoding: .utf8) else { throw DeviceTerminalInputRouter.InputError.invalidEncoding }
                var input = params
                input["text"] = text
                _ = try await link.request("mobile.terminal.input", params: input)
            },
            onFailure: { error in
                deviceMirrorLog.error("device terminal input failed: \(String(describing: error), privacy: .private)")
            }
        )
    }

    private var surfaceParams: [String: Any] {
        ["workspace_id": remoteWorkspaceID, "surface_id": remoteSurfaceID.uuidString]
    }

    /// Binds the local Ghostty surface: size reports drive viewport reports,
    /// runtime readiness samples the first grid, visibility lifts the cap.
    func bind(surface: TerminalSurface) {
        self.surface = surface
        surface.onManualSizeApplied = { [weak self] sample in self?.apply(size: sample) }
        surface.onRuntimeReady = { [weak self] in self?.runtimeReady() }
        surface.onManualWindowAttached = { [weak self] in self?.runtimeReady() }
        surface.onManualVisibilityChanged = { [weak self] visible in self?.visibilityChanged(visible) }
        surface.flushPendingManualSizeReportIfAttached()
    }

    func start() {
        guard phase == .idle else { return }
        phase = .attaching
        startEventConsumer()
        scheduleAttach()
    }

    func stop() {
        guard phase != .stopped else { return }
        let hadReport = viewportGeneration > 0
        phase = .stopped
        attachingBytes.removeAll()
        attachingByteCount = 0
        attachTask?.cancel()
        attachTask = nil
        eventTask?.cancel()
        eventTask = nil
        viewportTask?.cancel()
        viewportTask = nil
        inputRouter.invalidate()
        if let surface {
            surface.onManualSizeApplied = nil
            surface.onRuntimeReady = nil
            surface.onManualWindowAttached = nil
            surface.onManualVisibilityChanged = nil
            surface.clearAssignedGrid()
        }
        surface = nil
        if hadReport, link.isConnected {
            let params = clearViewportParams()
            Task { _ = try? await link.request("mobile.terminal.viewport", params: params) }
        }
    }

    // MARK: - Attach and bytes

    private func startEventConsumer() {
        let stream = link.terminalEvents.stream(surfaceID: remoteSurfaceID)
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
            // The host's terminal changed size (its pane resized, or another
            // viewer pinned a smaller grid): repaint at the new geometry.
            pin(columns: columns, rows: rows)
            scheduleAttach()
        case .resyncRequired:
            if link.isConnected {
                reportedGrid = nil
                scheduleAttach()
            } else if phase == .attached || phase == .attaching {
                phase = .detached
            }
        case .linkReconnected:
            reportedGrid = nil
            scheduleAttach()
        case .linkLost:
            if phase == .attached || phase == .attaching { phase = .detached }
        }
    }

    /// Single-flight replay: viewport report, then a full snapshot of the
    /// remote screen as VT bytes, then live bytes chained from its sequence.
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
        guard phase != .stopped, link.isConnected else {
            if phase != .stopped { phase = .detached }
            return
        }
        phase = .attaching
        attachingBytes.removeAll(keepingCapacity: true)
        attachingByteCount = 0
        if let grid = pendingGrid ?? reportedGrid ?? currentDesiredGrid() {
            await reportViewport(grid)
        }
        guard !Task.isCancelled, phase != .stopped else { return }
        do {
            let response = try await link.requestData("mobile.terminal.replay", params: surfaceParams)
            let replay = try await Self.decodeReplay(response)
            guard !Task.isCancelled, phase == .attaching, link.isConnected else { return }
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

    // MARK: - Geometry

    func runtimeReady() {
        guard phase != .stopped, let surface, surface.isNativeViewInRealWindow,
              let sample = surface.rawSizingSample() else { return }
        apply(size: sample)
    }

    func visibilityChanged(_ visible: Bool) {
        guard phase != .stopped else { return }
        isVisible = visible
        if visible {
            runtimeReady()
        } else if viewportGeneration > 0, link.isConnected {
            // A hidden pane must not keep capping the remote terminal.
            reportedGrid = nil
            pendingGrid = nil
            let params = clearViewportParams()
            viewportTask?.cancel()
            viewportTask = Task { [weak self] in
                _ = try? await self?.link.request("mobile.terminal.viewport", params: params)
                guard let self, self.isVisible, self.pendingGrid != nil, self.phase != .stopped else {
                    self?.viewportTask = nil
                    return
                }
                self.viewportTask = nil
                self.startViewportTask()
            }
        }
    }

    /// The grid this pane could show at its current size: the view's pixel
    /// bounds, minus the surface's own padding, in whole cells.
    static func desiredGrid(from sample: TerminalSurfaceRawSizingSample) -> (columns: Int, rows: Int)? {
        guard let bounds = sample.viewBoundsPt, let scale = sample.backingScale,
              bounds.width > 1, bounds.height > 1, scale > 0,
              sample.cellWidthPx > 0, sample.cellHeightPx > 0 else { return nil }
        let padWidth = max(0, sample.surfaceWidthPx - sample.columns * sample.cellWidthPx)
        let padHeight = max(0, sample.surfaceHeightPx - sample.rows * sample.cellHeightPx)
        let widthPx = Int((bounds.width * scale).rounded(.down)) - padWidth
        let heightPx = Int((bounds.height * scale).rounded(.down)) - padHeight
        let columns = widthPx / sample.cellWidthPx
        let rows = heightPx / sample.cellHeightPx
        guard columns >= 2, rows >= 2 else { return nil }
        return (min(max(columns, 20), 300), min(max(rows, 5), 120))
    }

    private func currentDesiredGrid() -> (columns: Int, rows: Int)? {
        guard let surface, surface.isNativeViewInRealWindow, let sample = surface.rawSizingSample() else { return nil }
        return Self.desiredGrid(from: sample)
    }

    func apply(size sample: TerminalSurfaceRawSizingSample) {
        guard phase != .stopped, isVisible, let grid = Self.desiredGrid(from: sample) else { return }
        if let reported = reportedGrid, reported.columns == grid.columns, reported.rows == grid.rows { return }
        pendingGrid = grid
        guard viewportTask == nil, phase == .attached || phase == .attaching else { return }
        startViewportTask()
    }

    private func startViewportTask() {
        guard viewportTask == nil else { return }
        viewportTask = Task { [weak self] in
            guard let self else { return }
            while let next = self.pendingGrid, self.phase != .stopped, self.isVisible, !Task.isCancelled {
                self.pendingGrid = nil
                await self.reportViewport(next)
            }
            self.viewportTask = nil
        }
    }

    private func reportViewport(_ grid: (columns: Int, rows: Int)) async {
        guard link.isConnected, isVisible, phase != .stopped else { return }
        viewportGeneration &+= 1
        let generation = viewportGeneration
        var params = surfaceParams
        params["client_id"] = link.clientID
        params["viewport_columns"] = grid.columns
        params["viewport_rows"] = grid.rows
        params["viewport_generation"] = viewportGeneration
        do {
            let response = try await link.request("mobile.terminal.viewport", params: params)
            guard !Task.isCancelled, phase != .stopped, isVisible, viewportGeneration == generation else { return }
            reportedGrid = grid
            if let columns = (response["columns"] as? NSNumber)?.intValue,
               let rows = (response["rows"] as? NSNumber)?.intValue, columns > 0, rows > 0 {
                pin(columns: columns, rows: rows)
            }
        } catch {
            deviceMirrorLog.error("device viewport report failed: \(String(describing: error), privacy: .private)")
        }
    }

    private func clearViewportParams() -> [String: Any] {
        viewportGeneration &+= 1
        var params = surfaceParams
        params["client_id"] = link.clientID
        params["clear"] = true
        params["viewport_generation"] = viewportGeneration
        return params
    }

    /// Pins the local grid to the host's effective grid; the view clips or
    /// letterboxes the difference, exactly as the remote Mac's own pane does.
    private func pin(columns: Int, rows: Int) {
        if let assigned = assignedGrid, assigned.columns == columns, assigned.rows == rows { return }
        assignedGrid = (columns, rows)
        surface?.setAssignedGrid(columns: columns, rows: rows)
    }
}

internal import CMUXMobileCore
public import CmuxMobileRPC
public import CmuxMobileTerminalKit
public import Foundation
public import Observation

/// A live view onto one remote terminal: the render-grid stream reduced into
/// a drawable ``HiveTerminalGridModel``, plus the keyboard input path.
///
/// Attach performs a `mobile.terminal.replay` (full grid snapshot), then
/// consumes `terminal.render_grid` push events filtered to this surface.
/// When the event stream dies the loop re-subscribes and re-replays with a
/// bounded backoff — the shared RPC client reconnects its transport on the
/// next request — so a network blip or host restart recovers in place.
@MainActor
@Observable
public final class HiveRemoteTerminalSession {
    /// The attach lifecycle state.
    public enum Phase: Equatable, Sendable {
        /// Not attached yet.
        case idle
        /// Replay requested; waiting for the first full frame.
        case attaching
        /// Live: frames are streaming.
        case live
        /// Stream lost; re-attaching in the background.
        case reattaching
    }

    /// The host workspace id this terminal belongs to.
    public let workspaceID: String
    /// The host surface id this session views.
    public let terminalID: String

    /// Attach lifecycle state.
    public private(set) var phase: Phase = .idle
    /// The reduced grid the view renders.
    public private(set) var grid = HiveTerminalGridModel()
    /// Optional native-surface sink: every applied frame is also emitted as
    /// VT bytes (a full frame as replacement bytes, a delta as patch bytes)
    /// so a manual-I/O ghostty surface can render the stream natively. The
    /// grid model keeps reducing in parallel for tests and fallbacks.
    @ObservationIgnored public var frameBytesHandler: (@MainActor (Data) -> Void)?

    @ObservationIgnored private let client: MobileCoreRPCClient
    @ObservationIgnored private let retryDelay: @Sendable (_ attempt: Int) async -> Void
    @ObservationIgnored private var attachTask: Task<Void, Never>?

    /// Creates a terminal view session over an already-connected client.
    ///
    /// - Parameters:
    ///   - client: The Mac session's shared RPC client.
    ///   - workspaceID: The host workspace id.
    ///   - terminalID: The host surface id to view.
    ///   - retryDelay: Awaited between re-attach attempts with the
    ///     consecutive-failure count (bounded backoff in production,
    ///     immediate in tests).
    public init(
        client: MobileCoreRPCClient,
        workspaceID: String,
        terminalID: String,
        retryDelay: @escaping @Sendable (_ attempt: Int) async -> Void
    ) {
        self.client = client
        self.workspaceID = workspaceID
        self.terminalID = terminalID
        self.retryDelay = retryDelay
    }

    /// Start the attach/replay/event loop. Idempotent while running.
    public func attach() {
        guard attachTask == nil else { return }
        phase = .attaching
        attachTask = Task { [weak self] in
            await self?.runAttachLoop()
        }
    }

    /// Stop the stream (view unmounted).
    public func detach() {
        attachTask?.cancel()
        attachTask = nil
        phase = .idle
    }

    /// Re-request a full replay snapshot, e.g. after the local mirror surface
    /// first applies its real size (a replay delivered to a zero-sized manual
    /// surface renders nothing until the next full frame).
    public func refreshReplay() {
        Task { [weak self] in
            try? await self?.requestReplay()
        }
    }

    // MARK: - Input

    /// Send typed text to the remote PTY (`terminal.input`).
    public func send(text: String) {
        guard !text.isEmpty else { return }
        sendInput(text)
    }

    /// Send a special key (arrows, escape, tab, …) encoded through the shared
    /// ``TerminalKeyEncoder`` byte tables.
    public func send(specialKey: TerminalSpecialKey, modifiers: TerminalKeyModifier = []) {
        guard let bytes = TerminalKeyEncoder.encode(specialKey: specialKey, modifiers: modifiers),
              let text = String(data: bytes, encoding: .utf8) else { return }
        sendInput(text)
    }

    /// Send a Control-modified character (`Ctrl+C` → 0x03, …).
    public func send(controlCharacter: String) {
        guard let bytes = TerminalKeyEncoder.controlCharacter(for: controlCharacter),
              let text = String(data: bytes, encoding: .utf8) else { return }
        sendInput(text)
    }

    private func sendInput(_ text: String) {
        let workspaceID = workspaceID
        let terminalID = terminalID
        let client = client
        Task {
            guard let request = try? MobileCoreRPCClient.requestData(
                method: "mobile.terminal.input",
                params: [
                    "workspace_id": workspaceID,
                    "surface_id": terminalID,
                    "text": text,
                ]
            ) else { return }
            // Fire-and-forget: a failed keystroke surfaces through the event
            // stream dying (reattach), not through per-key errors.
            _ = try? await client.sendRequest(request)
        }
    }

    // MARK: - Attach loop

    private func runAttachLoop() async {
        var consecutiveFailures = 0
        while !Task.isCancelled {
            // Register the local listener BEFORE the replay so no frame
            // emitted between the replay response and the subscription is lost.
            let stream = await client.subscribe(to: ["terminal.render_grid"])
            do {
                let subscribe = try MobileCoreRPCClient.requestData(
                    method: "mobile.events.subscribe",
                    params: ["topics": ["terminal.render_grid"]]
                )
                _ = try await client.sendRequest(subscribe)
                try await requestReplay()
                consecutiveFailures = 0
                phase = .live
            } catch is CancellationError {
                return
            } catch {
                consecutiveFailures += 1
                if Task.isCancelled { return }
                phase = .reattaching
                await retryDelay(consecutiveFailures)
                continue
            }
            for await envelope in stream {
                guard let payload = envelope.payloadJSON,
                      let frame = Self.decodeFrame(payload),
                      frame.surfaceID == terminalID else { continue }
                applyFrame(frame)
            }
            // Stream finished: transport died. Re-subscribe + re-replay.
            if Task.isCancelled { return }
            phase = .reattaching
            consecutiveFailures += 1
            await retryDelay(consecutiveFailures)
        }
    }

    private func requestReplay() async throws {
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.terminal.replay",
            params: [
                "workspace_id": workspaceID,
                "surface_id": terminalID,
            ]
        )
        let data = try await client.sendRequest(request)
        let response = try MobileTerminalReplayResponse.decode(data)
        if let frame = response.renderGrid {
            applyFrame(frame)
        }
    }

    private func applyFrame(_ frame: MobileTerminalRenderGridFrame) {
        grid.apply(frame)
        guard let frameBytesHandler else { return }
        let replay = MobileTerminalRenderGridReplay(frame)
        frameBytesHandler(frame.full ? replay.replacementBytes() : replay.patchBytes())
    }

    /// Decode one `terminal.render_grid` event payload: either the wrapped
    /// `{"render_grid": …}` form or the bare frame.
    static func decodeFrame(_ payload: Data) -> MobileTerminalRenderGridFrame? {
        if let event = try? MobileTerminalRenderGridEvent.decode(payload), let frame = event.frame {
            return frame
        }
        return try? JSONDecoder().decode(MobileTerminalRenderGridFrame.self, from: payload)
    }
}

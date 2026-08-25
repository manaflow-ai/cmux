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
    /// The most recent full frame as replacement bytes, kept so a surface
    /// that realizes (or resizes) after the replay landed can be repainted
    /// immediately without a network round-trip.
    @ObservationIgnored public private(set) var lastFullFrameBytes: Data?

    @ObservationIgnored private let client: MobileCoreRPCClient
    @ObservationIgnored private let retryDelay: @Sendable (_ attempt: Int) async -> Void
    @ObservationIgnored private let renderGridDecoder: HiveRemoteRenderGridDecoder
    @ObservationIgnored private var attachTask: Task<Void, Never>?
    @ObservationIgnored private var replayTask: Task<Void, Never>?
    @ObservationIgnored private var frameApplyTask: Task<Void, Never>?
    @ObservationIgnored private var pendingFrames: [MobileTerminalRenderGridFrame] = []
    @ObservationIgnored private var frameQueueNeedsReplay = false
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    @ObservationIgnored private var pendingInput: [String] = []
    @ObservationIgnored private var pendingInputBytes = 0
    @ObservationIgnored private let maximumPendingInputBytes = 64 * 1024
    @ObservationIgnored private var inputGeneration = 0

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
        self.renderGridDecoder = HiveRemoteRenderGridDecoder()
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
        replayTask?.cancel()
        replayTask = nil
        frameApplyTask?.cancel()
        frameApplyTask = nil
        pendingFrames.removeAll(keepingCapacity: true)
        frameQueueNeedsReplay = false
        inputGeneration &+= 1
        inputTask?.cancel()
        inputTask = nil
        pendingInput.removeAll(keepingCapacity: true)
        pendingInputBytes = 0
        phase = .idle
    }

    /// Re-request a full replay snapshot, e.g. after the local mirror surface
    /// first applies its real size (a replay delivered to a zero-sized manual
    /// surface renders nothing until the next full frame).
    public func refreshReplay() {
        replayTask?.cancel()
        replayTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.requestReplay()
            } catch is CancellationError {
                return
            } catch {
                // The attach loop owns recovery; a manual refresh is best
                // effort and must not create a second recovery loop.
            }
            self.replayTask = nil
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
        guard phase == .live || phase == .reattaching else { return }
        enqueueInput(text)
        startInputWorkerIfNeeded()
    }

    private func startInputWorkerIfNeeded() {
        guard inputTask == nil, phase == .live else { return }
        let generation = inputGeneration
        inputTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.inputGeneration == generation {
                    self.inputTask = nil
                }
            }
            while !Task.isCancelled {
                guard let text = self.dequeueInput(for: generation) else { break }
                var requestStarted = false
                do {
                    let request = try MobileCoreRPCClient.requestData(
                        method: "mobile.terminal.input",
                        params: [
                            "workspace_id": self.workspaceID,
                            "surface_id": self.terminalID,
                            "text": text,
                        ]
                    )
                    try Task.checkCancellation()
                    requestStarted = true
                    _ = try await self.client.sendRequest(request)
                } catch is CancellationError {
                    return
                } catch {
                    // Keep the lifecycle truthful when an input request fails;
                    // the attach loop will re-establish the stream.
                    if !requestStarted {
                        enqueueInput(text, atFront: true)
                    } else {
                        // A lost response is ambiguous: the host may already
                        // have applied these non-idempotent bytes. Drop the
                        // remainder rather than duplicating a command after
                        // reconnect; the phase change tells the user to retry.
                        pendingInput.removeAll(keepingCapacity: true)
                        pendingInputBytes = 0
                    }
                    if self.inputGeneration == generation, self.phase == .live {
                        self.phase = .reattaching
                        self.attachTask?.cancel()
                        self.attachTask = nil
                        self.attach()
                    }
                    return
                }
            }
        }
    }

    private func dequeueInput(for generation: Int) -> String? {
        guard generation == inputGeneration, phase == .live, !pendingInput.isEmpty else { return nil }
        let text = pendingInput.removeFirst()
        pendingInputBytes -= text.utf8.count
        return text
    }

    private func enqueueInput(_ text: String, atFront: Bool = false) {
        let bytes = text.utf8.count
        guard bytes <= maximumPendingInputBytes else { return }
        while pendingInputBytes + bytes > maximumPendingInputBytes, !pendingInput.isEmpty {
            pendingInputBytes -= pendingInput.removeFirst().utf8.count
        }
        if atFront {
            pendingInput.insert(text, at: 0)
        } else {
            pendingInput.append(text)
        }
        pendingInputBytes += bytes
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
                guard !Task.isCancelled else { return }
                consecutiveFailures = 0
                phase = .live
                startInputWorkerIfNeeded()
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
                      let frame = await decodeFrameOffMain(payload),
                      frame.surfaceID == terminalID else { continue }
                guard !Task.isCancelled else { return }
                enqueueFrame(frame)
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
        let decoder = renderGridDecoder
        let response = try await Task.detached(priority: .userInitiated) {
            try decoder.decodeReplay(data)
        }.value
        try Task.checkCancellation()
        guard let frame = response.renderGrid else {
            throw HiveRemoteTerminalSessionError.missingFrame
        }
        guard frame.full, frame.surfaceID == terminalID else {
            throw frame.surfaceID == terminalID
                ? HiveRemoteTerminalSessionError.incompleteFrame
                : HiveRemoteTerminalSessionError.mismatchedSurface
        }
        pendingFrames.removeAll(keepingCapacity: true)
        applyFrame(frame, allowingFullReset: true)
    }

    private func enqueueFrame(_ frame: MobileTerminalRenderGridFrame) {
        if pendingFrames.count >= 256 {
            pendingFrames.removeAll(keepingCapacity: true)
            frameQueueNeedsReplay = true
        }
        pendingFrames.append(frame)
        guard frameApplyTask == nil else { return }
        frameApplyTask = Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            let frames = self.pendingFrames
            self.pendingFrames.removeAll(keepingCapacity: true)
            for frame in frames {
                self.applyFrame(frame)
            }
            let needsReplay = self.frameQueueNeedsReplay
            self.frameQueueNeedsReplay = false
            let remaining = needsReplay ? [] : self.pendingFrames
            self.pendingFrames.removeAll(keepingCapacity: true)
            self.frameApplyTask = nil
            if needsReplay {
                self.refreshReplay()
            }
            for frame in remaining {
                self.enqueueFrame(frame)
            }
        }
    }

    private func applyFrame(
        _ frame: MobileTerminalRenderGridFrame,
        allowingFullReset: Bool = false
    ) {
        guard grid.apply(frame, allowingFullReset: allowingFullReset) else { return }
        let replay = MobileTerminalRenderGridReplay(frame)
        let bytes = frame.full ? replay.replacementBytes() : replay.patchBytes()
        if frame.full { lastFullFrameBytes = bytes }
        frameBytesHandler?(bytes)
    }

    /// Decode one `terminal.render_grid` event payload: either the wrapped
    /// `{"render_grid": …}` form or the bare frame.
    private func decodeFrameOffMain(_ payload: Data) async -> MobileTerminalRenderGridFrame? {
        let decoder = renderGridDecoder
        return await Task.detached(priority: .userInitiated) {
            decoder.decodeFrame(payload)
        }.value
    }
}

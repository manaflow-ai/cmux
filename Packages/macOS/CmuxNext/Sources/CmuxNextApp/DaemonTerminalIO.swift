import CmuxNextDaemon
import CmuxNextTerminal
import Foundation
import Synchronization
import os

/// Bridges one daemon terminal attachment (`TerminalByteChannel`) to a
/// Ghostty surface (`TerminalIO`).
///
/// - Attaches on its own connection without claiming geometry, so showing a
///   tab never reflows the PTY. The first settled grid report claims it.
/// - Maps replays (plain or with Kitty state) and output in order; a replay
///   is preceded by its grid so follower views size correctly.
/// - `overflow` (this view fell behind) re-attaches for a fresh replay.
/// - Grid reports go through `ResizeCoordinator` and reach the daemon only
///   after the view stops resizing.
nonisolated final class DaemonTerminalIO: TerminalIO {
    struct Target: Sendable {
        var attachment: TerminalAttachment.Target
        var initialSize: CellSize
    }

    private struct State {
        var attachment: TerminalAttachment?
        var claimed = false
        var visible = true
        var closed = false
        var lastSize: CellSize?
    }

    let events: AsyncStream<TerminalIOEvent>
    private let continuation: AsyncStream<TerminalIOEvent>.Continuation
    private let state = Mutex(State())
    private let target: Target
    private let endpoint: @Sendable () async throws -> DaemonEndpoint
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.terminal")
    private let pump = Mutex<Task<Void, Never>?>(nil)

    init(target: Target, endpoint: @escaping @Sendable () async throws -> DaemonEndpoint) {
        self.target = target
        self.endpoint = endpoint
        (events, continuation) = AsyncStream.makeStream(of: TerminalIOEvent.self, bufferingPolicy: .unbounded)
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.run()
        }
        pump.withLock { $0 = task }
    }

    deinit {
        pump.withLock { $0?.cancel() }
    }

    // MARK: TerminalIO

    /// The daemon's VT core answers DA/DSR, so the surface mirrors only.
    var answersTerminalQueries: Bool { true }

    func write(_ data: Data) async {
        state.withLock { $0.attachment }?.enqueueInput(data)
    }

    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {
        guard cols > 0, rows > 0 else { return }
        let size = CellSize(cols: cols, rows: rows)
        await MainActor.run { ResizeCoordinator.shared.submit(self, size: size) }
    }

    // MARK: App control

    /// Called by `ResizeCoordinator` once the size settled.
    @MainActor func applySettled(_ size: CellSize) {
        let (attachment, claim) = state.withLock { state -> (TerminalAttachment?, Bool) in
            state.lastSize = size
            let claim = state.visible && !state.claimed && state.attachment != nil
            if claim { state.claimed = true }
            return (state.attachment, claim)
        }
        guard let attachment else { return }
        Task {
            await attachment.resize(cols: size.cols, rows: size.rows, pixelWidth: 0, pixelHeight: 0)
            if claim { await attachment.claimGeometry() }
        }
    }

    /// Hidden views release canonical geometry so another client (or the
    /// next visible view) owns it; shown views claim it again.
    @MainActor func setVisible(_ visible: Bool) {
        let (attachment, action) = state.withLock { state -> (TerminalAttachment?, Bool?) in
            guard state.visible != visible else { return (nil, nil) }
            state.visible = visible
            if !visible, state.claimed {
                state.claimed = false
                return (state.attachment, false)
            }
            if visible, !state.claimed, state.lastSize != nil, state.attachment != nil {
                state.claimed = true
                return (state.attachment, true)
            }
            return (nil, nil)
        }
        guard let attachment, let action else { return }
        Task { action ? await attachment.claimGeometry() : await attachment.releaseGeometry() }
    }

    /// Ends the attachment. The terminal keeps running in the daemon.
    func close() {
        let attachment = state.withLock { state -> TerminalAttachment? in
            state.closed = true
            defer { state.attachment = nil }
            return state.attachment
        }
        pump.withLock { $0?.cancel() }
        if let attachment { Task { await attachment.detach() } }
        continuation.finish()
        Task { @MainActor in ResizeCoordinator.shared.cancel(self) }
    }

    // MARK: Pump

    private func run() async {
        var attempts = 0
        while !Task.isCancelled, !state.withLock({ $0.closed }) {
            let attachment: TerminalAttachment
            do {
                let endpoint = try await endpoint()
                let size = state.withLock { $0.lastSize } ?? target.initialSize
                attachment = try await TerminalAttachment.attach(endpoint: endpoint, target: target.attachment,
                                                                 size: size, claimGeometry: false)
            } catch {
                logger.error("attach \(self.target.attachment.surface.rawValue) failed: \(String(describing: error), privacy: .public)")
                break
            }
            // A visible view owns canonical geometry at the size it attached with.
            let claimNow = state.withLock { state -> Bool in
                state.attachment = attachment
                state.claimed = state.visible && state.lastSize != nil
                return state.claimed
            }
            if claimNow { await attachment.claimGeometry() }
            let reason = await forward(attachment)
            state.withLock { $0.attachment = nil }
            guard reason == .overflow, attempts < 8 else { break }
            attempts += 1
            logger.info("terminal \(self.target.attachment.surface.rawValue) overflowed; re-attaching")
        }
        continuation.finish()
    }

    /// Forwards one attachment's stream. Returns why it ended.
    private func forward(_ attachment: TerminalAttachment) async -> TerminalChannelCloseReason? {
        var outputs = 0
        for await event in attachment.events {
            if case .output = event { outputs += 1; if outputs <= 3 || outputs % 100 == 0 { logger.notice("NXDBG surface \(self.target.attachment.surface.rawValue) output #\(outputs)") } }
            if case .replay(let r) = event { logger.notice("NXDBG surface \(self.target.attachment.surface.rawValue) replay \(r.cols)x\(r.rows) \(r.data.count)B") }
            if case .resized(let r) = event { logger.notice("NXDBG surface \(self.target.attachment.surface.rawValue) resized \(r.cols)x\(r.rows)") }
            if case .closed(let reason) = event { logger.notice("NXDBG surface \(self.target.attachment.surface.rawValue) closed \(String(describing: reason), privacy: .public)") }
            switch event {
            case .replay(let replay), .resized(let replay):
                continuation.yield(.resize(cols: replay.cols, rows: replay.rows))
                continuation.yield(Self.replayEvent(replay))
            case .output(let data, _):
                continuation.yield(.output(data))
            case .colorsChanged, .scrollChanged:
                break
            case .closed(let reason):
                if reason == .surfaceGone { continuation.yield(.exited) }
                return reason
            }
        }
        return nil
    }

    /// A replay with usable Kitty graphics state restores it; otherwise the
    /// plain VT bytes replay (ghostty.h requires nonzero image-id cursors).
    static func replayEvent(_ replay: TerminalReplay) -> TerminalIOEvent {
        guard let kitty = replay.kittyGraphicsState,
              kitty.primaryReplayNextImageID != 0, kitty.alternateReplayNextImageID != 0,
              kitty.primaryNextImageID != 0, kitty.alternateNextImageID != 0
        else { return .replay(replay.data) }
        return .kittyReplay(TerminalKittyReplay(
            vt: replay.data,
            cursorOffset: kitty.replayCursorOffset,
            limits: .init(imageBytes: kitty.imageBytes, inflightBytes: kitty.inflightBytes,
                          images: kitty.images, placements: kitty.placements),
            replayCursors: .init(primary: kitty.primaryReplayNextImageID, alternate: kitty.alternateReplayNextImageID),
            nextCursors: .init(primary: kitty.primaryNextImageID, alternate: kitty.alternateNextImageID),
            aliases: replay.kittyImageAliases.map { .init(imageID: $0.imageID, imageNumber: $0.imageNumber) }
        ))
    }
}

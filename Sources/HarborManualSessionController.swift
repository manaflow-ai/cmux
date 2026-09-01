import AppKit
import CmuxTerminal
import CmuxTerminalCore
import CmuxTmuxControlMode
import Foundation
import os

/// Non-actor cleanup token for a source owned by a panel. Explicit panel
/// close is the normal lifecycle. This token is the safety net for a teardown
/// path that releases a panel without calling `close()`, and it can stop a
/// transport without touching AppKit or main-actor state.
private final class HarborManualSessionLifetime: @unchecked Sendable {
    let source: any TerminalSessionSource
    // This is a synchronous compare-and-set from `stop()`/`deinit` callbacks.
    // The transport itself is not guarded by this lock; its lifecycle method
    // is invoked exactly once after the bit is claimed. The package
    // architecture permits this narrow non-blocking callback carve-out.
    private let state = OSAllocatedUnfairLock(initialState: false)

    init(source: any TerminalSessionSource) {
        self.source = source
    }

    func stop() {
        let shouldStop = state.withLock { didStop -> Bool in
            guard !didStop else { return false }
            didStop = true
            return true
        }
        guard shouldStop else { return }
        source.stop()
    }

    deinit {
        stop()
    }
}

/// Connects one session-owned transport to one manual Ghostty surface.
///
/// The controller owns the attachment lifecycle. The source owns the remote
/// terminal and is never asked to create a second terminal. The surface owns
/// the local emulator and reports its applied cell grid back to the source.
@MainActor
final class HarborManualSessionController: TerminalSessionSourceDelegate {
    private struct GridSize: Equatable, Sendable {
        let columns: Int
        let rows: Int
        let cellWidthPixels: Int
        let cellHeightPixels: Int

        var terminalSize: TerminalSize {
            TerminalSize(
                columns: columns,
                rows: rows,
                cellWidthPixels: cellWidthPixels,
                cellHeightPixels: cellHeightPixels
            )
        }
    }

    enum State: Equatable {
        case connecting
        case live
        case ended(reason: String?)
        case failed(reason: String)
    }

    let source: any TerminalSessionSource
    private let lifetime: HarborManualSessionLifetime
    private weak var surface: TerminalSurface?
    private var didStartSource = false
    private var stopped = false
    private var resizeTask: Task<Void, Never>?
    private var lastSentGrid: GridSize?
    private var pendingGrid: GridSize?
    private var scrollQuantizer = TerminalManualScrollQuantizer()
    /// Injected clock operation keeps resize coalescing deterministic in
    /// tests and makes cancellation part of the lifecycle contract.
    private let sleep: @Sendable (Duration) async throws -> Void

    /// AppKit can emit a short sequence of intermediate cell grids while a
    /// window or split settles. A trailing coalescer prevents each transient
    /// grid from becoming a remote SIGWINCH/redraw while preserving the final
    /// applied grid. The first grid still starts immediately below.
    private static let resizeDebounce = Duration.milliseconds(180)

    private(set) var state: State = .connecting {
        didSet {
            guard state != oldValue else { return }
            surface?.owningWorkspace()?.postRemoteConnectionPresentationDidChange()
            onStateChange?()
        }
    }
    var onStateChange: (() -> Void)?

    var overlayPresentation: CloudTerminalReconnectOverlayPolicy.Presentation? {
        switch state {
        case .connecting, .live:
            return nil
        case let .ended(reason):
            let detail = reason.map {
                String(
                    format: String(
                        localized: "harbor.overlay.ended.detailWithReason",
                        defaultValue: "The terminal session ended: %@"
                    ),
                    $0
                )
            } ?? String(
                localized: "harbor.overlay.ended.detail",
                defaultValue: "The terminal session ended. Close the tab, or keep the final screen."
            )
            return CloudTerminalReconnectOverlayPolicy.Presentation(
                title: String(localized: "harbor.overlay.ended.title", defaultValue: "Terminal session ended"),
                detail: detail,
                showsProgress: false,
                showsReconnectButton: false
            )
        case let .failed(reason):
            return CloudTerminalReconnectOverlayPolicy.Presentation(
                title: String(localized: "harbor.overlay.failed.title", defaultValue: "Terminal backend unavailable"),
                detail: String(
                    format: String(
                        localized: "harbor.overlay.failed.detail",
                        defaultValue: "The terminal source failed: %@"
                    ),
                    reason
                ),
                showsProgress: false,
                showsReconnectButton: false
            )
        }
    }

    init(
        source: any TerminalSessionSource,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.source = source
        self.lifetime = HarborManualSessionLifetime(source: source)
        self.sleep = sleep
    }

    /// Ghostty calls this closure from its IO thread. The source contract is
    /// Sendable and serializes its own transport, so no UI state crosses that
    /// boundary.
    nonisolated func makeManualInputHandler() -> @Sendable (TerminalManualInput) -> Void {
        let source = source
        return { input in
            switch input {
            case .bytes(let bytes):
                source.sendInput(Array(bytes))
            case .namedKey(let name):
                source.sendNamedKey(name)
            }
        }
    }

    func start(surface: TerminalSurface) {
        guard !stopped else { return }
        self.surface = surface
        // Keep the safe preserve-screen behavior until the source classifies
        // its foreground. A first resize must never reflow a TUI frame.
        surface.setManualIONoReflow(true)
        surface.onManualSizeApplied = { [weak self] sample in
            self?.applyGrid(sample)
        }
        surface.onRuntimeReady = { [weak self, weak surface] in
            guard let self, let surface else { return }
            surface.flushPendingManualSizeReportIfAttached()
            self.sampleGrid(of: surface)
        }
        surface.onManualScroll = { [weak self] event in
            self?.routeManualScroll(event) ?? false
        }
        surface.flushPendingManualSizeReportIfAttached()
        sampleGrid(of: surface)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        resizeTask?.cancel()
        resizeTask = nil
        pendingGrid = nil
        scrollQuantizer.reset()
        lifetime.stop()
        surface?.onManualSizeApplied = nil
        surface?.onRuntimeReady = nil
        surface?.onManualScroll = nil
    }

    private func sampleGrid(of surface: TerminalSurface) {
        guard let sample = surface.rawSizingSample(), sample.columns > 1, sample.rows > 1 else { return }
        applyGrid(sample)
    }

    private func applyGrid(_ sample: TerminalSurfaceRawSizingSample) {
        guard !stopped, sample.columns > 1, sample.rows > 1 else { return }
        let grid = GridSize(
            columns: sample.columns,
            rows: sample.rows,
            cellWidthPixels: max(0, sample.cellWidthPx),
            cellHeightPixels: max(0, sample.cellHeightPx)
        )
        if !didStartSource {
            didStartSource = true
            lastSentGrid = grid
            pendingGrid = nil
            source.start(
                initialSize: grid.terminalSize,
                delegate: self
            )
            return
        }
        if lastSentGrid == grid {
            // The window returned to the last acknowledged size while a
            // trailing resize was waiting. Cancel that stale intent instead
            // of sending an unnecessary round trip.
            pendingGrid = nil
            resizeTask?.cancel()
            resizeTask = nil
            return
        }
        guard source.supportsExactResize else {
            // A source such as Zellij's documented subscribe client does not
            // own the server layout and has no exact viewer-resize command.
            // Mark this grid observed and avoid sending a relative pane-layout
            // action that would resize the user's foreign session.
            lastSentGrid = grid
            pendingGrid = nil
            resizeTask?.cancel()
            resizeTask = nil
            return
        }
        guard pendingGrid != grid else { return }
        pendingGrid = grid
        resizeTask?.cancel()
        let source = source
        let sleep = sleep
        resizeTask = Task { @MainActor [weak self] in
            do {
                try await sleep(Self.resizeDebounce)
            } catch {
                return
            }
            guard let self, !self.stopped,
                  self.pendingGrid == grid,
                  self.lastSentGrid != grid else { return }
            self.resizeTask = nil
            self.pendingGrid = nil
            self.lastSentGrid = grid
            source.resize(grid.terminalSize)
        }
    }

    /// A rendered-frame source must receive viewport movement as a semantic
    /// command. Returning false for unsupported or malformed events leaves
    /// the native Ghostty path available for byte-stream sources.
    private func routeManualScroll(_ event: TerminalManualScrollEvent) -> Bool {
        guard !stopped, source.supportsSemanticScroll else { return false }
        guard event.deltaY.isFinite, event.deltaY != 0 else { return false }
        if event.isPrecise,
           !event.cellHeightPixels.isFinite || event.cellHeightPixels <= 0 {
            return false
        }
        if let command = scrollQuantizer.command(for: event) {
            source.sendScroll(command)
        }
        // A fractional precise event is consumed even when it does not yet
        // make a full row. Forwarding it to Ghostty would move a second,
        // non-authoritative viewport and lose the accumulated remainder.
        return true
    }

    func controlModeSession(didProduceSnapshot bytes: [UInt8]) {
        consumeSnapshot(bytes)
    }

    func controlModeSession(didProduceOutput bytes: [UInt8]) {
        consumeOutput(bytes)
    }

    func controlModeSession(didChangeResizePolicy policy: TerminalSessionResizePolicy) {
        applyResizePolicy(policy)
    }

    func controlModeSession(didEndWithReason reason: String?) {
        finish(termination: .ended(reason: reason))
    }

    func controlModeSession(didTerminate termination: TerminalSessionTermination) {
        finish(termination: termination)
    }

    private func consumeSnapshot(_ bytes: [UInt8]) {
        guard !stopped else { return }
        surface?.processRemoteOutput(Data(bytes))
        state = .live
    }

    private func consumeOutput(_ bytes: [UInt8]) {
        guard !stopped else { return }
        surface?.processRemoteOutput(Data(bytes))
        state = .live
    }

    private func applyResizePolicy(_ policy: TerminalSessionResizePolicy) {
        guard !stopped else { return }
        surface?.setManualIONoReflow(policy.suppressesLocalReflow)
    }

    private func finish(termination: TerminalSessionTermination) {
        guard !stopped else { return }
        stopped = true
        resizeTask?.cancel()
        resizeTask = nil
        pendingGrid = nil
        scrollQuantizer.reset()
        lifetime.stop()
        surface?.onManualSizeApplied = nil
        surface?.onRuntimeReady = nil
        surface?.onManualScroll = nil
        switch termination {
        case let .ended(reason):
            state = .ended(reason: reason)
        case let .failed(reason):
            state = .failed(reason: reason)
        }
    }
}

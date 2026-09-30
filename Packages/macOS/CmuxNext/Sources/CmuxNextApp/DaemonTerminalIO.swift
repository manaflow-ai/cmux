import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextTerminal
import Foundation
import os

/// Bridges one daemon terminal attachment (`TerminalAttachment`) to a
/// Ghostty surface (`TerminalIO`).
///
/// The attachment lifecycle is one `TerminalAttachMachine` run by a
/// `TerminalAttachDriver` (state-audit.md T1, T3-T5):
/// - Attaches on its own connection without claiming geometry, so showing a
///   tab never reflows the PTY. The first settled grid report after the
///   replay claims it while the view renders (SurfaceLedger visibility).
/// - Input typed while attaching or reattaching is queued and sent once, in
///   order, after the replay. Grid reports meanwhile are coalesced.
/// - Maps replays (plain or with Kitty state) and output in order through a
///   bounded step queue; a replay is preceded by its grid so the mirror
///   sizes before parsing it. A daemon `resized` is only a grid change.
/// - `overflow` (this view fell behind, the daemon's 8 MiB limit) detaches
///   the old link and reattaches for a fresh replay.
/// - Closing during an attach ends the view at once and detaches the link
///   the attach returns, with its lease, as soon as it completes.
/// - Geometry follows tmux "window-size latest" (`TerminalAttachMachine`):
///   a visible view claims on each settled resize and, after another client
///   sized the terminal, on its next key press or focus.
/// - Grid reports go through `ResizeCoordinator` and reach the daemon only
///   after the view stops resizing.
nonisolated final class DaemonTerminalIO: TerminalIO {
    struct Target: Sendable {
        var attachment: TerminalAttachment.Target
        var initialSize: CellSize
    }

    let events: AsyncStream<TerminalIOEvent>
    private let driver: TerminalAttachDriver<TerminalAttachment>

    init(target: Target, visible: Bool = true, endpoint: @escaping @Sendable () async throws -> DaemonEndpoint) {
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.terminal")
        let surface = target.attachment.surface.rawValue
        let driver = TerminalAttachDriver<TerminalAttachment>(
            initialSize: target.initialSize,
            visible: visible,
            opener: { size in
                try await TerminalAttachment.attach(endpoint: try await endpoint(), target: target.attachment,
                                                    size: size, claimGeometry: false)
            },
            onFailure: { error in
                logger.error("attach \(surface) failed: \(String(describing: error), privacy: .public)")
            },
            onReattach: { attempt in
                logger.info("terminal \(surface) fell behind; reattaching for a fresh replay (open \(attempt))")
            },
            observer: InputJournal.shared.isEnabled ? InputJournal.attachObserver(surface: String(surface)) : nil
        )
        self.driver = driver
        events = AsyncStream(unfolding: { await driver.nextStep().map(Self.event(for:)) },
                             onCancel: { driver.cancelSteps() })
        driver.start()
    }

    deinit {
        driver.close()
    }

    // MARK: TerminalIO

    /// The daemon's VT core answers DA/DSR, so the surface mirrors only.
    var answersTerminalQueries: Bool { true }

    func write(_ data: Data) async {
        driver.input(data)
    }

    /// Focus takes geometry back after another client sized the terminal.
    func focusGained() async {
        driver.focused()
    }

    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {
        guard cols > 0, rows > 0 else { return }
        let size = CellSize(cols: cols, rows: rows)
        await MainActor.run { ResizeCoordinator.shared.submit(self, size: size) }
    }

    // MARK: App control

    /// Called by `ResizeCoordinator` once the size settled.
    @MainActor func applySettled(_ size: CellSize) {
        driver.resize(size)
    }

    /// Hidden views release canonical geometry so another client (or the
    /// next visible view) owns it; shown views claim it again.
    @MainActor func setVisible(_ visible: Bool) {
        driver.setVisible(visible)
    }

    /// Ends the attachment (or cancels the attach in flight). The terminal
    /// keeps running in the daemon.
    @MainActor func close() {
        driver.close()
        ResizeCoordinator.shared.cancel(self)
    }

    /// Attachment state for diagnostics and tests.
    var attachPhase: TerminalAttachDriver<TerminalAttachment>.Machine.Phase { driver.machine.phase }

    // MARK: Steps

    private static func event(for step: TerminalStreamPlan.Step) -> TerminalIOEvent {
        switch step {
        case .grid(let columns, let rows): .resize(cols: columns, rows: rows)
        case .replay(let replay): replayEvent(replay)
        case .output(let data): .output(data)
        case .exited: .exited
        }
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

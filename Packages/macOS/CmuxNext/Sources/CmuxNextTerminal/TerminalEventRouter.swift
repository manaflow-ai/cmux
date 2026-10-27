import CmuxNextCompat
import CmuxNextTerminalGeometry
import Foundation
import GhosttyNextKit

/// Takes one session's IO events off the main actor, in stream order (ghostty-integration-DESIGN.md
/// G4, p03-rendering-085). Output, echo marks, grid locks and snapshot restores go straight to the
/// surface's output lane; the grid, status, chip, exit and content bookkeeping the main actor shows
/// goes to the session's ``TerminalEventMailbox``, applied once per frame. The loop waits for the main
/// actor only for a replay into a surface that has content: Ghostty has no reset API, so the session
/// makes a new surface (an AppKit view) and hands back its lane (``replace``).
///
/// Chrome's compositor works the same way: input and frame-ordered state reach the compositor
/// thread without a main-thread round trip (`cc/input/input_handler.h`,
/// `cc/trees/layer_tree_host_impl.cc`), and only what the main thread owns is posted to it.
nonisolated struct TerminalEventRouter: Sendable {
    /// The lane later events go to: the session's live surface's (nil: it has no surface).
    private(set) var lane: TerminalOutputLane?
    /// The live surface was handed content (output, a replay, or a READY the lane restored): a later
    /// replay needs a fresh one. A READY counts only once the lane says it restored (``restored``).
    private(set) var hasContent = false
    /// The live surface's READYs the lane restored: set from the lane's result, on its queue.
    private var restored = TerminalRestoredContent()
    /// A READY was queued on the live surface's lane since the loop last read ``restored``.
    private var restoreQueued = false
    let mailbox: TerminalEventMailbox
    /// The session's input to the IO: a local-history mismatch asks it for a fresh READY.
    let input: TerminalInputSink
    /// Swaps in a fresh surface for a replay on the main actor and queues the replay on its lane;
    /// returns that lane (nil: the session is gone).
    let replace: @Sendable (TerminalIOEvent) async -> TerminalOutputLane??

    init(lane: TerminalOutputLane?, mailbox: TerminalEventMailbox, input: TerminalInputSink,
         replace: @escaping @Sendable (TerminalIOEvent) async -> TerminalOutputLane??) {
        self.lane = lane
        self.mailbox = mailbox
        self.input = input
        self.replace = replace
    }

    /// Routes `event`. False once the session is gone.
    mutating func route(_ event: TerminalIOEvent) async -> Bool {
        if let lane, await lane.takeOffMain(event) {
            if case .output = event { contentQueued() }
            return true
        }
        switch event {
        case .replay(let data):
            return await replay(event, vt: data)
        case .kittyReplay(let replay):
            // GhosttyNextKit restores Kitty graphics through GHOSTSNP snapshots
            // (terminal-snapshot-v1), not the desktop fork's kitty replay. Until
            // this view attaches in snapshot mode (S2b), the VT part is
            // replayed and on-screen Kitty images come back only when the
            // program draws them again.
            return await self.replay(event, vt: replay.vt)
        case .snapshot(let data, let phase):
            await restore(data, phase: phase)
        case .resize(let columns, let rows):
            guard columns > 0, rows > 0 else { return true }
            let grid = TerminalGridSize(columns: columns, rows: rows)
            lane?.lockGrid(grid)
            mailbox.post { $0.grid = grid }
        case .exited:
            mailbox.post { $0.exited = true }
        case .status(let status):
            mailbox.post { $0.set(status) }
        case .sizedFor(let sizedFor):
            mailbox.post { $0.setSizedFor(sizedFor) }
        case .output, .inputEcho:
            break // no lane: nothing to parse into
        }
        return true
    }

    /// A replay goes into the live surface while it has no content, else into a fresh one.
    private mutating func replay(_ event: TerminalIOEvent, vt: Data) async -> Bool {
        guard await surfaceHasContent() else {
            lane?.processOutput(vt)
            contentRestored()
            return true
        }
        guard let fresh = await replace(event) else { return false }
        lane = fresh
        restored = TerminalRestoredContent()
        restoreQueued = false
        return true
    }

    /// Restores GHOSTSNP bytes on the lane in stream order, behind earlier output and the grid lock
    /// of the preceding `.resize` (a READY keeps that lock's generation and takes its size).
    private mutating func restore(_ data: Data, phase: TerminalSnapshotPhase) async {
        guard let lane else { return }
        let mailbox = mailbox, content = restored
        switch phase {
        case .ready:
            // ghostty-next applies this surface's palette, default colors and
            // cursor defaults to the restored terminal itself (local policy,
            // GhosttyNextKit 68ac618db), keeping the program's overrides.
            // A READY Ghostty refused leaves the terminal as it was: no content.
            restoreQueued = true
            lane.restoreSnapshot(data, phase: GHOSTTY_SURFACE_SNAPSHOT_READY) { restored in
                guard restored else { return }
                content.set()
                mailbox.post {
                    $0.readyRestores += 1
                    $0.contentQueued = true
                }
            }
        case .history:
            await lane.waitForCapacity()
            lane.restoreSnapshot(data, phase: GHOSTTY_SURFACE_SNAPSHOT_HISTORY)
        case .readyLocalHistory(let local):
            // The restore reflows the old grid itself (no set_grid); on a mismatch the READY is
            // restored without history and the IO is asked for a fresh READY + history, on an error
            // the IO is asked as well.
            // An error (a closed lane too) changed nothing: no content.
            let grid = TerminalGridSize(columns: local.columns, rows: local.rows)
            let input = input
            restoreQueued = true
            lane.restoreLocalHistory(data, expectedRows: local.historyRows, digest: local.digest, grid: grid) { result in
                switch result {
                case Int32(GHOSTTY_SURFACE_LOCAL_HISTORY_RESTORED.rawValue):
                    content.set()
                    mailbox.post {
                        $0.localSnapshots += 1
                        $0.readyRestores += 1
                        $0.contentQueued = true
                    }
                case Int32(GHOSTTY_SURFACE_LOCAL_HISTORY_MISMATCH.rawValue):
                    content.set()
                    input.resync()
                    mailbox.post {
                        $0.localHistoryMismatches += 1
                        $0.readyRestores += 1
                        $0.contentQueued = true
                    }
                default:
                    input.resync()
                    mailbox.post { $0.localHistoryMismatches += 1 }
                }
            }
            mailbox.post { $0.grid = grid }
        case .images(let skipped):
            await lane.waitForCapacity()
            lane.applyKittyReplay(data)
            if skipped > 0 { mailbox.post { $0.skippedImages += skipped } }
        }
    }

    /// Whether the live surface has content. A READY still on the lane is waited for (off main), so a
    /// replay after a READY Ghostty refused goes into the same, empty surface.
    private mutating func surfaceHasContent() async -> Bool {
        if !hasContent, restoreQueued, let lane { await lane.drained() }
        restoreQueued = false
        if restored.value { hasContent = true }
        return hasContent
    }

    /// Output was queued on the live surface's lane: the first content's bookkeeping follows on the
    /// main actor's frame. Later output into a surface with content costs the main actor nothing.
    private mutating func contentQueued() {
        if restored.value { hasContent = true }
        guard !hasContent else { return }
        contentRestored()
    }

    /// A whole screen (a replay) was queued on the live surface's lane: content for the main
    /// actor's bookkeeping, each time.
    private mutating func contentRestored() {
        hasContent = true
        mailbox.post { $0.contentQueued = true }
    }
}

/// One surface's READY restores that its output lane reported: set from the lane's result callback
/// on the lane's queue, read by the events loop (``TerminalEventRouter``).
nonisolated final class TerminalRestoredContent: Sendable {
    private let restored = Atomic<Bool>(false)

    /// A READY (or a local-history READY) restored into the surface.
    var value: Bool { restored.load(ordering: .acquiring) }

    func set() { restored.store(true, ordering: .releasing) }
}

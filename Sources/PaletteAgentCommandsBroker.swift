import AppKit
import CmuxCommandPalette
import Foundation

extension Notification.Name {
    /// Asks a window's `ContentView` to project its command palette rows for
    /// `palette.list`. `object` is the target window (`nil` means the key
    /// window, the same default every other command palette request uses), and
    /// `userInfo` carries the request id under
    /// `PaletteAgentCommandsBroker.requestIdKey`.
    static let commandPaletteAgentCommandsRequested = Notification.Name(
        "cmux.commandPalette.agentCommandsRequested"
    )
}

/// One window's answer to a `palette.list` request.
struct PaletteAgentCommandsReply: Sendable {
    /// The identity of the window that answered, so the caller can tell which
    /// window's palette it is looking at when it did not name one.
    let windowId: UUID?
    let commands: [CommandPaletteAgentCommand]
}

/// How one `palette.list` wait ended, apart from the timeout the awaiter
/// reports as nil.
enum PaletteAgentCommandsOutcome: Sendable {
    /// The window projected its rows.
    case answered(PaletteAgentCommandsReply)
    /// The target window closed between being resolved and being asked, so
    /// nothing was ever going to answer this request.
    case windowClosed
}

/// Matches `palette.list` requests to the window that answers them.
///
/// `palette.list` has to report the palette as it stands now, and the rules that
/// decide that (`when`, `enablement`, config overrides) are closures owned by
/// `ContentView` and evaluated against state only the view reads. So the socket
/// worker cannot compute the listing: it asks, and waits. This broker holds the
/// pending question. The worker registers a continuation here, posts
/// `.commandPaletteAgentCommandsRequested`, and blocks in `socketAwaitCallback`;
/// the matching window fulfills it from inside its own body.
///
/// A request is answered at most once: `fulfill` removes the waiter before
/// calling it, so a second window, or a re-delivered notification, is a no-op
/// instead of a double reply. A request nobody answers is never fulfilled, and
/// the worker's timeout turns that into a `timeout` error.
@MainActor
final class PaletteAgentCommandsBroker {
    static let shared = PaletteAgentCommandsBroker()

    /// `userInfo` key carrying the request's `UUID`.
    static let requestIdKey = "cmux.commandPalette.agentCommandsRequestId"

    private var waiters: [UUID: (PaletteAgentCommandsReply) -> Void] = [:]

    init() {}

    /// Registers `completion` under `id`, then asks `window` to answer.
    ///
    /// `window` is nil only for a caller that means "whichever window has the
    /// keyboard". `palette.list` never does: it resolves its target first, so an
    /// agent's request is answered by a named window even when cmux is in the
    /// background and there is no key window at all.
    func request(
        id: UUID,
        window: NSWindow?,
        completion: @escaping (PaletteAgentCommandsReply) -> Void
    ) {
        waiters[id] = completion
        NotificationCenter.default.post(
            name: .commandPaletteAgentCommandsRequested,
            object: window,
            userInfo: [Self.requestIdKey: id]
        )
    }

    /// Answers `id` if it is still pending; answering twice does nothing.
    func fulfill(id: UUID, reply: PaletteAgentCommandsReply) {
        guard let completion = waiters.removeValue(forKey: id) else { return }
        completion(reply)
    }

    /// Drops a waiter whose caller stopped waiting, so a late answer neither
    /// fires nor keeps the continuation alive.
    ///
    /// This cannot arrive before the registration it is meant to drop: both hop
    /// to this actor from the same socket-worker call at the same priority, the
    /// registration first and the cancel only after the wait expires, so they
    /// run in that order even when the main actor was blocked for the whole
    /// timeout. Cancelling an id that is not pending is therefore a caller that
    /// never registered one, not a race, and doing nothing is right.
    func cancel(id: UUID) {
        waiters.removeValue(forKey: id)
    }
}

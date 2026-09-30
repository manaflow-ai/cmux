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

    /// Registers `completion` under `id`, then asks `window` (or the key window
    /// when `window` is `nil`) to answer.
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
    func cancel(id: UUID) {
        waiters.removeValue(forKey: id)
    }

    /// Whether `id` is still waiting. Used by tests and by the socket method to
    /// avoid posting a cancel for a request that already answered.
    func isPending(id: UUID) -> Bool {
        waiters[id] != nil
    }
}

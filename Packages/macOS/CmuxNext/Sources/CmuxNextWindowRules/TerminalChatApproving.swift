import Foundation
import Observation

/// The terminal face of a pair, as its approval is read and answered: the daemon's agent state for
/// it (an `@Observable` read, so a change is heard), its viewport's text, and its keys.
@MainActor public protocol TerminalApprovalTerminal: AnyObject {
    /// The agent in the terminal waits on the person (the hooks' Blocked).
    var approvalBlocked: Bool { get }
    /// The viewport's text, one line per row; nil when it cannot be read.
    func approvalScreen() async -> String?
    /// Presses `keys` (`up`, `down`, `enter`) in the terminal, as its program reads keys; false when refused.
    func approvalPress(_ keys: [String]) async -> Bool
}

/// The chat face of a pair: shows the terminal's dialog as its permission card (nil: none), and
/// sends a click on it to `answer` (the option's number and label, and the id of the dialog the card showed).
@MainActor public protocol TerminalApprovalChat: AnyObject {
    func showTerminalApproval(_ approval: WindowRules.TerminalApproval?,
                              answer: @escaping @MainActor (_ key: Int, _ label: String, _ id: String) async -> Bool)
}

/// Toggle Terminal and Chat's approval (Leo, 2026-11-12: two live views of one session, instant both
/// ways): while the terminal drives the session, its harness's approval dialog shows in the chat and
/// is answered from it. The screen is read only while the agent is Blocked, on each change of its
/// state (the hooks report a PermissionRequest as Blocked and the answer's tool as Working), and
/// twice more, shortly after, when a Blocked screen shows no dialog yet (the hook can report before the
/// harness draws). The parse and the keys are Rust's (cmux-window-rules `tabs::approval`). A click types
/// only while the terminal still shows that very dialog (its id: the question, the command and the
/// rest), with that option, and the harness still in the foreground.
@MainActor public final class TerminalChatApproving {
    private weak var terminal: (any TerminalApprovalTerminal)?
    private weak var chat: (any TerminalApprovalChat)?
    private let rules = WindowRules()
    /// The dialog the chat shows now.
    public private(set) var shown: WindowRules.TerminalApproval?
    /// Each read's number: a slower read that ends after a newer one shows nothing.
    private var reads = 0
    private var watching = false
    private var stopped = false
    /// The waits before the re-reads of a Blocked screen that showed no dialog.
    static let rereads: [Duration] = [.milliseconds(250), .seconds(1)]

    public init(terminal: any TerminalApprovalTerminal, chat: any TerminalApprovalChat) {
        self.terminal = terminal
        self.chat = chat
    }

    /// Reads now and again on each change of the terminal's agent state, until either face is gone.
    public func start() {
        guard !watching, !stopped else { return }
        watching = true
        watch()
        // task-owner: the first read of a watch; later reads follow the agent state's changes
        Task { await refresh() }
    }

    private func watch() {
        guard let terminal, chat != nil else { return stop() }
        _ = withObservationTracking { terminal.approvalBlocked } onChange: { [weak self] in
            // task-owner: one read per observed change, re-armed; ends with either face
            Task { @MainActor [weak self] in
                guard let self, self.watching else { return }
                self.watch()
                await self.refresh()
            }
        }
    }

    /// Stops reading for good and takes the card down.
    public func stop() {
        watching = false
        stopped = true
        show(nil)
    }

    /// The dialog on the terminal's screen now, shown in the chat (or the card taken down).
    public func refresh() async {
        await refresh(rereads: Self.rereads[...])
    }

    private func refresh(rereads: ArraySlice<Duration>) async {
        guard !stopped else { return }
        reads += 1
        let read = reads
        guard let terminal, chat != nil else { return stop() }
        guard terminal.approvalBlocked else { return show(nil) }
        let screen = await terminal.approvalScreen()
        guard read == reads, !stopped else { return }
        let found = screen.flatMap { rules.terminalApproval(screen: $0) }
        show(found)
        guard found == nil, let wait = rereads.first else { return }
        // wakeup-allow: two bounded re-reads of a Blocked screen the harness had not drawn yet; a newer read cancels them
        try? await Task.sleep(for: wait)
        guard read == reads else { return }
        await refresh(rereads: rereads.dropFirst())
    }

    /// A click on the card: the keys from the terminal's cursor to option `key`, then Enter, read
    /// against its screen now; false (nothing typed) when the agent no longer waits, or the screen no
    /// longer shows dialog `id` with that option, or the harness left the foreground.
    public func answer(key: Int, label: String, id: String) async -> Bool {
        guard let terminal, !stopped, terminal.approvalBlocked, let screen = await terminal.approvalScreen(),
              let keys = rules.terminalApprovalKeys(screen: screen, key: key, label: label, id: id),
              await terminal.approvalPress(keys) else {
            await refresh()
            return false
        }
        // Answered: the card goes at once. The next state change reads what the terminal asks next, and so does
        // one read shortly after, for a queued dialog that keeps the agent Blocked (no state change).
        reads += 1
        show(nil)
        // task-owner: one re-read after an answer; a stopped watch or a newer read drops it
        Task { [weak self] in
            // wakeup-allow: one bounded re-read after an answer, for a queued dialog with no state change
            try? await Task.sleep(for: Self.rereads[0])
            await self?.refresh()
        }
        return true
    }

    private func show(_ approval: WindowRules.TerminalApproval?) {
        guard approval != shown else { return }
        shown = approval
        chat?.showTerminalApproval(approval) { [weak self] key, label, id in
            await self?.answer(key: key, label: label, id: id) ?? false
        }
    }
}

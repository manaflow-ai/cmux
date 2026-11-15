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
/// sends a click on it to `answer` (the option's number and label, and the question the card showed).
@MainActor public protocol TerminalApprovalChat: AnyObject {
    func showTerminalApproval(_ approval: WindowRules.TerminalApproval?,
                              answer: @escaping @MainActor (_ key: Int, _ label: String, _ question: String) async -> Bool)
}

/// Toggle Terminal and Chat's approval (Leo, 2026-11-12: two live views of one session, instant both
/// ways): while the terminal drives the session, its harness's approval dialog shows in the chat and
/// is answered from it. The screen is read only while the agent is Blocked, on each change of its
/// state (the hooks report a PermissionRequest as Blocked and the answer's tool as Working); the
/// parse and the keys are Rust's (cmux-window-rules `tabs::approval`). A click types only while the
/// terminal still shows that question with that option. Nothing polls.
@MainActor public final class TerminalChatApproving {
    private weak var terminal: (any TerminalApprovalTerminal)?
    private weak var chat: (any TerminalApprovalChat)?
    private let rules = WindowRules()
    /// The dialog the chat shows now.
    public private(set) var shown: WindowRules.TerminalApproval?
    /// Each read's number: a slower read that ends after a newer one shows nothing.
    private var reads = 0
    private var watching = false

    public init(terminal: any TerminalApprovalTerminal, chat: any TerminalApprovalChat) {
        self.terminal = terminal
        self.chat = chat
    }

    /// Reads now and again on each change of the terminal's agent state, until either face is gone.
    public func start() {
        guard !watching else { return }
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

    /// Stops reading and takes the card down.
    public func stop() {
        watching = false
        show(nil)
    }

    /// The dialog on the terminal's screen now, shown in the chat (or the card taken down).
    public func refresh() async {
        reads += 1
        let read = reads
        guard let terminal, chat != nil else { return stop() }
        guard terminal.approvalBlocked else { return show(nil) }
        let screen = await terminal.approvalScreen()
        guard read == reads, watching else { return }
        show(screen.flatMap { rules.terminalApproval(screen: $0) })
    }

    /// A click on the card: the keys from the terminal's cursor to option `key`, then Enter, read
    /// against its screen now; false (nothing typed) when it no longer asks `question` with that option.
    public func answer(key: Int, label: String, question: String) async -> Bool {
        guard let terminal, let screen = await terminal.approvalScreen(),
              let keys = rules.terminalApprovalKeys(screen: screen, key: key, label: label, question: question),
              await terminal.approvalPress(keys) else {
            await refresh()
            return false
        }
        // Answered: the card goes at once; the next state change reads what the terminal asks next.
        reads += 1
        show(nil)
        return true
    }

    private func show(_ approval: WindowRules.TerminalApproval?) {
        guard approval != shown else { return }
        shown = approval
        chat?.showTerminalApproval(approval) { [weak self] key, label, question in
            await self?.answer(key: key, label: label, question: question) ?? false
        }
    }
}

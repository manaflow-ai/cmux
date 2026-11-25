public import AppKit
import CmuxNextCompat
public import CmuxNextDaemonService
public import CmuxNextDiff
import Foundation

/// Every terminal's comment threads (`terminal.sendSelectionToChat`, diff-comments-threads-v1): one
/// ``CommentThreadsModel`` per session host and root, and the card that shows them over a terminal.
/// The action's binding owns one.
@MainActor
public final class TerminalCommentThreads {
    private var models: [String: CommentThreadsModel] = [:]
    private let popup = TerminalCommentsPopup()
    /// Threads whose answer the card has shown, so one reply reopens it once.
    private var shownAnswers: Set<String> = []
    /// Per terminal: reopens its card when a reply comes while it is closed.
    private var watches: [String: Task<Void, Never>] = [:]

    public init() {}

    /// Where one comment goes.
    public struct Target {
        public let terminal: CommentedTerminal
        /// The workspace chat's acpmux session.
        public let acpSession: String
        /// The chat's session host.
        public let link: AgentPaneGitLink
        /// The threads' key on the session host: the chat's folder, else the terminal's.
        public let root: String

        public init(terminal: CommentedTerminal, acpSession: String, link: AgentPaneGitLink, root: String) {
            self.terminal = terminal
            self.acpSession = acpSession
            self.link = link
            self.root = root
        }
    }

    /// Saves and sends `message` on `quote` to `target`'s chat under a fresh opid (the person's
    /// Add to Chat click), then shows its thread over `anchor`. `failed` gets the refusal text.
    public func send(_ message: String, quote: String, to target: Target, anchor: NSView,
                     failed: @escaping @MainActor (String) -> Void) {
        let model = model(for: target.link, root: target.root)
        let terminalID = target.terminal.id
        // task-owner: one save and send on the session host; ends when the send answers.
        Task { [weak self, weak anchor] in
            do {
                try await model.comment(on: target.terminal, quote: quote, message: message,
                                        acpSession: target.acpSession, key: "terminal-comment-" + UUID().uuidString)
            } catch {
                return failed(TerminalCommentStrings.notSent)
            }
            guard let self, let anchor else { return }
            self.popup.show(model, terminalID: terminalID, anchor: anchor, makeKey: false)
            self.watch(model, terminalID: terminalID, anchor: anchor)
        }
    }

    private func model(for link: AgentPaneGitLink, root: String) -> CommentThreadsModel {
        let key = "\(ObjectIdentifier(link).hashValue)|\(root)"
        if let model = models[key] { return model }
        let model = CommentThreadsModel(root: root, store: DiffAgentGit(link: link))
        models[key] = model
        return model
    }

    /// Reopens the card over `anchor` when one of the terminal's threads gets its answer while the
    /// card is closed; ends when none waits.
    private func watch(_ model: CommentThreadsModel, terminalID: String, anchor: NSView) {
        watches[terminalID]?.cancel()
        // task-owner: follows the terminal's threads until none waits; replaced by the next send.
        watches[terminalID] = Task { [weak self, weak anchor] in
            for await threads in ObservationStream({ model.threads(onTerminal: terminalID) }) {
                guard let self, let anchor else { return }
                let answered = Set(threads.filter { $0.state == .answered }.map(\.id))
                if !answered.subtracting(self.shownAnswers).isEmpty, !self.popup.isShown {
                    self.popup.show(model, terminalID: terminalID, anchor: anchor, makeKey: false)
                }
                self.shownAnswers.formUnion(answered)
                if !threads.contains(where: { $0.state == .sent }) { return }
            }
        }
    }
}

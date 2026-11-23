import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDiff
import CmuxNextPages
import Foundation
import Observation

/// Comment… on a terminal selection (`terminal.sendSelectionToChat`, comment-threads-v1): the
/// person types a comment on the selected text in the cmux comment dialog, and Add to Chat saves it
/// on the session host as a terminal comment (`diff.comments.save {surface: "terminal"}`) and sends
/// it to the agent chat of the terminal's workspace (the one design mode sends to) in one step
/// (`diff.comments.send {keep: true}`). The comment stays as a thread: a card over the terminal
/// shows the quote, the comment, "Sent" and then the agent's reply, which `diff.comments.list`
/// brings back (polled every 2 s while a thread waits); Resolve deletes it.
///
/// A session host without `comment-threads-v1` keeps the row as the terminal-to-chat placeholder
/// (``TerminalToChatPlaceholders``): left out of the menus and refused with its reason.
enum TerminalCommentHandlers {
    static let id: ActionID = "terminal.sendSelectionToChat"

    /// Where one comment goes: the terminal, the workspace's chat and its session host.
    struct Target {
        let terminal: TabModel
        let session: String
        let link: AgentPaneGitLink
        /// The chat's folder, else the terminal's: the threads' key on the session host.
        let root: String
    }

    @MainActor
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        registry.bind(id, invoke: { invocation in
            guard invocation.isPersonsOwnRun else { return ctx.refuse(TerminalCommentStrings.gesture) }
            let target: Target
            switch resolve(invocation, ctx) {
            case .success(let found): target = found
            case .failure(let reason): return ctx.refuse(reason.message)
            }
            guard let entry = ctx.terminal(invocation) else { return }
            guard let quote = TerminalHandlers.selection(of: entry) else { return ctx.refuse(RefusalStrings.nothingSelected) }
            let anchor = entry.session.surfaceView
            guard let window = anchor.window else { return }
            let title = target.terminal.displayTitle.isEmpty ? TerminalCommentStrings.terminal : target.terminal.displayTitle
            // ChatQuote titles a source by its last path component; a terminal title is not a path.
            let prompt = ViewerCommentPrompt(quote: ChatQuote(source: title.replacingOccurrences(of: "/", with: "\u{2215}"),
                                                              kind: .code, quoted: quote))
            prompt.run(in: window) { commented in
                // Add to Chat is the person's click: the save and the send run now, under a fresh opid.
                TerminalCommentThreads.shared.send(commented.comment, quote: quote, to: target, anchor: anchor,
                                                   refuse: { ctx.refuse($0) })
            }
        })
        ActionTargetVisibility.gate(id, in: registry, reason: { invocation in
            if case .failure(let reason) = resolve(invocation, ctx) { return reason.message }
            return nil
        })
        ActionTargetTitles.set(id, in: registry) { _ in TerminalCommentStrings.menuTitle }
    }

    /// Why a terminal cannot take a comment.
    enum Unavailable: Error {
        /// Not a terminal.
        case notATerminal
        /// The workspace has no agent chat with a session.
        case noChat
        /// The chat's session host keeps no threads: the placeholder's reason.
        case noThreads

        var message: String {
            switch self {
            case .notATerminal: RefusalStrings.notATerminal
            case .noChat: TerminalCommentStrings.noChat
            case .noThreads: TerminalToChatPlaceholders.reason
            }
        }
    }

    /// The target of `invocation`: its terminal, the chat it sends to and that chat's session host.
    /// Reads no live view and selects nothing, so a menu can ask it.
    @MainActor
    static func resolve(_ invocation: ActionInvocation, _ ctx: AppActionContext) -> Result<Target, Unavailable> {
        let services = ctx.services
        guard let (tab, pane) = ctx.daemonTab(invocation), tab.kind == .pty || tab.kind == .remoteTerminal else {
            return .failure(.notATerminal)
        }
        guard let chat = services.workspaceAgentChat(near: pane),
              let session = chat.tab.agentSession?.session, !session.isEmpty else { return .failure(.noChat) }
        guard let link = services.viewers.diffPages.gitLink(for: chat.tab), link.keepsCommentThreads else {
            return .failure(.noThreads)
        }
        let folder = NewTerminalStart.folder(of: chat.tab, services: services) ?? tab.cwd
        guard let root = folder, root.hasPrefix("/") else { return .failure(.noChat) }
        return .success(Target(terminal: tab, session: session, link: link, root: root))
    }
}

/// Every terminal's comment threads, one ``CommentThreadsModel`` per session host and root, and the
/// card that shows them.
@MainActor
final class TerminalCommentThreads {
    static let shared = TerminalCommentThreads() // lint:allow singleton: one store of terminal comment threads for the app.

    private var models: [String: CommentThreadsModel] = [:]
    /// Replies already shown, so one reply reopens the card once.
    private var shownReplies: Set<String> = []

    private init() {}

    /// The threads of `root` on `link`'s session host.
    func model(for link: AgentPaneGitLink, root: String) -> CommentThreadsModel {
        let key = "\(ObjectIdentifier(link).hashValue)|\(root)"
        if let model = models[key] { return model }
        let model = CommentThreadsModel(root: root, store: DiffAgentGit(link: link))
        models[key] = model
        return model
    }

    /// Saves and sends `message` on `quote` to `target`'s chat, then shows its thread over `anchor`.
    func send(_ message: String, quote: String, to target: TerminalCommentHandlers.Target, anchor: NSView,
              refuse: @escaping @MainActor (String) -> Void) {
        let model = model(for: target.link, root: target.root)
        let terminal = CommentedTerminal(id: target.terminal.id, title: target.terminal.displayTitle, cwd: target.terminal.cwd)
        let key = "terminal-comment-" + UUID().uuidString
        // task-owner: one save and send on the session host; ends when the send answers.
        Task { @MainActor [weak anchor] in
            do {
                try await model.comment(on: terminal, quote: quote, message: message, acpSession: target.session, key: key)
            } catch {
                return refuse(TerminalCommentStrings.notSent)
            }
            guard let anchor else { return }
            TerminalCommentsPopup.shared.show(model, terminalID: terminal.id, anchor: anchor, makeKey: false)
            self.watchReplies(model, terminalID: terminal.id, anchor: anchor)
        }
    }

    /// Reopens the card over `anchor` when a reply to one of the terminal's threads comes while it is closed.
    private func watchReplies(_ model: CommentThreadsModel, terminalID: String, anchor: NSView) {
        let answered = { model.threads(onTerminal: terminalID).filter { $0.state != .sent }.map(\.id) }
        shownReplies.formUnion(answered())
        guard model.isWaiting else { return }
        _ = withObservationTracking { model.threads(onTerminal: terminalID) } onChange: { [weak self, weak anchor] in
            Task { @MainActor in
                guard let self, let anchor else { return }
                let new = Set(answered()).subtracting(self.shownReplies)
                if !new.isEmpty, !TerminalCommentsPopup.shared.isShown {
                    TerminalCommentsPopup.shared.show(model, terminalID: terminalID, anchor: anchor, makeKey: false)
                }
                self.watchReplies(model, terminalID: terminalID, anchor: anchor)
            }
        }
    }
}

import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDiff
import CmuxNextPages
import CmuxNextTerminalComments
import Foundation

/// Comment… on a terminal selection (`terminal.sendSelectionToChat`, comment-threads-v1): the cmux
/// comment dialog takes a comment on the selected text, and Add to Chat saves it on the chat's
/// session host as a terminal comment and sends it to the workspace's agent chat (the one design
/// mode sends to) with `keep: true`, so it stays as a thread whose reply shows in a card over the
/// terminal (``TerminalCommentThreads``). Without comment-threads-v1 the row stays the placeholder
/// (``TerminalToChatPlaceholders``): out of the menus and refused with its reason.
enum TerminalCommentHandlers {
    static let id: ActionID = "terminal.sendSelectionToChat"

    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        let threads = TerminalCommentThreads()
        registry.bindEffect(id, effect: { invocation in
            guard invocation.isPersonsOwnRun else { return .refused(TerminalCommentStrings.gesture) }
            let target: TerminalCommentThreads.Target
            switch resolve(invocation, ctx) {
            case .success(let found): target = found
            case .failure(let reason): return .refused(reason.text)
            }
            guard let entry = ctx.terminal(invocation) else { return .done }
            guard let quote = TerminalHandlers.selection(of: entry) else { return .refused(RefusalStrings.nothingSelected) }
            let anchor = entry.session.surfaceView
            guard let window = anchor.window else { return .refused(RefusalStrings.notATerminal) }
            // ChatQuote titles a source by its last path component; a terminal title is not a path.
            let title = (target.terminal.title ?? "").isEmpty ? TerminalCommentStrings.terminal : target.terminal.title ?? ""
            ViewerCommentPrompt(quote: ChatQuote(source: title.replacingOccurrences(of: "/", with: "\u{2215}"), kind: .code, quoted: quote))
                .run(in: window) { commented in
                    threads.send(commented.comment, quote: quote, to: target, anchor: anchor, failed: { ctx.refuse($0) })
                }
            return .done
        })
        ActionTargetVisibility.gate(id, in: registry, reason: { invocation in
            if case .failure(let reason) = resolve(invocation, ctx) { return reason.text }
            return nil
        })
        ActionTargetTitles.set(id, in: registry) { _ in TerminalCommentStrings.menuTitle }
    }

    /// Why a terminal cannot take a comment.
    enum Unavailable: Error {
        case notATerminal, noChat, noThreads

        var text: String {
            switch self {
            case .notATerminal: RefusalStrings.notATerminal
            case .noChat: TerminalCommentStrings.noChat
            case .noThreads: TerminalToChatPlaceholders.reason
            }
        }
    }

    /// The terminal `invocation` names, the workspace chat it sends to and that chat's session host
    /// (which must keep threads). Reads no live view and selects nothing, so a menu can ask it.
    static func resolve(_ invocation: ActionInvocation, _ ctx: AppActionContext) -> Result<TerminalCommentThreads.Target, Unavailable> {
        let services = ctx.services
        guard let (tab, pane) = ctx.daemonTab(invocation), tab.kind == .pty || tab.kind == .remoteTerminal else { return .failure(.notATerminal) }
        guard let chat = services.workspaceAgentChat(near: pane), let session = chat.tab.agentSession?.session, !session.isEmpty else {
            return .failure(.noChat)
        }
        guard let link = services.viewers.diffPages.gitLink(for: chat.tab), link.keepsCommentThreads else { return .failure(.noThreads) }
        guard let root = NewTerminalStart.folder(of: chat.tab, services: services) ?? tab.cwd, root.hasPrefix("/") else { return .failure(.noChat) }
        let terminal = CommentedTerminal(id: tab.id, title: tab.displayTitle, cwd: tab.cwd)
        return .success(.init(terminal: terminal, acpSession: session, link: link, root: root))
    }
}

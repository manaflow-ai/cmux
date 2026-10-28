import AppKit
import CmuxNextActions
import CmuxNextPages
import CmuxNextSettings

/// Comment… and Quote in Chat on selected text in the Markdown and editor pages
/// (viewer-comments-DESIGN.md): the page reports the selection and its source lines
/// (`cmux.<page>.selection`), and the quote goes to its chat through ``ChatQuoteDelivery``.
extension FilePageService {
    /// The selection menu of tab `key`'s page; `then` adds the page's own rows after it (the table rows).
    func installSelectionMenu(on page: PageWebView, key: String, then: (@MainActor (NSMenu) -> Void)? = nil) {
        var rows: [ViewerSelectionMenu.Row] = [
            .init(title: ViewerSelectionMenu.Titles.comment) { [weak self, weak page] in
                if let page { self?.quoteSelection(of: key, page: page, askComment: true) }
            },
            .init(title: ViewerSelectionMenu.Titles.quoteInChat) { [weak self, weak page] in
                if let page { self?.quoteSelection(of: key, page: page, askComment: false) }
            },
        ]
        // Send to Chief and Send To… (the terminal's and pages' rows): they run on the selected text.
        let registry = services?.registry
        for id in ["home.sendSelectionToChief", "home.sendSelectionTo"] as [ActionID] {
            guard let registry, let title = registry.title(for: id) else { continue }
            rows.append(.init(title: title) { [weak self, weak page] in
                if let page { self?.performOnSelection(id, of: key, page: page, registry: registry) }
            })
        }
        ViewerSelectionMenu(rows: rows, then: then).install(on: page)
    }

    /// Reads the page's selected text, then runs action `id` on it as a reply on tab `key`'s queue.
    private func performOnSelection(_ id: ActionID, of key: String, page: PageWebView, registry: ActionRegistry) {
        // The read is the page's own (main-actor) call, so the operation runs isolated to the main actor:
        // the page view is not Sendable and never leaves it.
        replies.reply(for: key) { @MainActor [weak page] in await page?.selectedText() } apply: { text in
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            _ = registry.perform(id, invocation: ActionInvocation(arguments: ["text": .string(text)], origin: .user))
        }
    }

    /// Reads the page's selection, asks for a comment when `askComment`, and sends the quote.
    func quoteSelection(of key: String, page: PageWebView, askComment: Bool) {
        guard let file = file(key) else { return }
        let op = kind.op("selection")
        let viewer: ChatQuote.Kind = kind == .markdown ? .markdown : .code
        // The page's call (the router fails it when the page closes), then the quote and its prompt as a
        // reply on the tab's queue. The call goes through the page's router (main-actor isolated, so
        // Sendable); the page view itself is not Sendable and stays with the main-actor reply.
        let router = page.router
        replies.reply(for: key) { [router] in
            try? await router.callPage(op, params: .object([:]))
        } apply: { [weak self, weak page] reply in
            guard let page, let reply, let quote = ChatQuote(selection: reply, source: file.path, kind: viewer) else { return }
            let deliver = { [weak self, weak page] (quote: ChatQuote) in
                guard let services = self?.services else { return }
                ChatQuoteDelivery(services: services).deliver(quote, from: page?.window)
            }
            guard askComment else { return deliver(quote) }
            guard let window = page.window else { return }
            ViewerCommentPrompt(quote: quote).run(in: window) { [weak self] quote in
                deliver(quote)
                // The comment also stays in the Markdown viewer, as a margin marker on its lines.
                guard let provider = self?.provider(key) else { return }
                // task-owner: one store write per added comment; ends when the write does. It only starts it.
                Task { @concurrent in _ = await provider.addComment(quote) }
            }
        }
    }
}

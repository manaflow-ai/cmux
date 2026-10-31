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
        let registry = services.registry
        for id in ["home.sendSelectionToChief", "home.sendSelectionTo"] as [ActionID] {
            guard let title = registry.title(for: id) else { continue }
            rows.append(.init(title: title) { [weak page] in
                // task-owner: one selection read per menu choice; ends with the page's answer
                Task { @MainActor in
                    guard let text = await page?.selectedText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    _ = registry.perform(id, invocation: ActionInvocation(arguments: ["text": .string(text)], origin: .user))
                }
            })
        }
        ViewerSelectionMenu(rows: rows, then: then).install(on: page)
    }

    /// Reads the page's selection, asks for a comment when `askComment`, and sends the quote.
    func quoteSelection(of key: String, page: PageWebView, askComment: Bool) {
        guard let file = file(key) else { return }
        let op = kind.op("selection")
        let viewer: ChatQuote.Kind = kind == .markdown ? .markdown : .code
        // task-owner: one page call per menu choice; ends with the page's reply (the router fails it when the page closes).
        Task { @MainActor [weak self, weak page] in
            guard let page, let reply = try? await page.router.callPage(op, params: .object([:])),
                  let quote = ChatQuote(selection: reply, source: file.path, kind: viewer) else { return }
            let deliver = { [weak self, weak page] (quote: ChatQuote) in
                guard let self else { return }
                ChatQuoteDelivery(services: self.services).deliver(quote, from: page?.window)
            }
            guard askComment else { return deliver(quote) }
            guard let window = page.window else { return }
            ViewerCommentPrompt(quote: quote).run(in: window) { [weak self] quote in
                deliver(quote)
                // The comment also stays in the Markdown viewer, as a margin marker on its lines.
                guard let provider = self?.provider(key) else { return }
                // task-owner: one store write per added comment; ends when the write does.
                Task { @MainActor in await provider.addComment(quote) }
            }
        }
    }
}

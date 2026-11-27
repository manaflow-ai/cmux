import AppKit
import CmuxNextPalette

/// Presents the composer's source pages using the same controller as Cmd-Shift-P. A pane made over
/// ``AgentPaneShared/projectPalette`` makes one (``AgentPaneView/init(model:source:renderRate:pageHost:shared:)``).
@MainActor
final class ProjectPaletteBridge {
    private weak var view: AgentPaneView?
    private let controller: @MainActor () -> PaletteController?
    private var session: String?
    private var rootLevel: Int?
    private var pages: [Page] = []

    init(view: AgentPaneView, controller: @escaping @MainActor () -> PaletteController?) {
        self.view = view
        self.controller = controller
    }

    /// The chat's pane laid out again (a split opened or closed beside it): an open source page follows it.
    func paneMoved() {
        guard session != nil, let palette = controller(), palette.isVisible else { return }
        palette.anchorMoved()
    }

    func respond(_ request: AgentProjectPaletteRequest) -> Bool {
        guard let palette = controller(), let view else { return false }
        switch request.operation {
        case .show(let model):
            guard model.page == .add, session == nil, let window = view.window else { return false }
            let page = Page(model)
            session = request.id
            pages = [page]
            palette.show(page: spec(for: page, session: request.id), relativeTo: window, anchor: view)
            rootLevel = palette.model.nav.top?.id
            return true
        case .update(let model, let push):
            guard session == request.id, palette.isVisible, let page = pages.last else { return false }
            if !push, model.page == page.model.page {
                let changed = page.model != model
                page.model = model
                if let waiting = page.waiting, waiting.query == model.query {
                    page.waiting = nil
                    answer(waiting.answer, for: page)
                } else if changed, page.query == model.query {
                    palette.model.reload()
                }
                return true
            }
            guard push, model.page.parent == page.model.page else { return false }
            let child = Page(model)
            pages.append(child)
            palette.model.push(spec(for: child, session: request.id))
            return true
        case .close:
            guard session == request.id else { return false }
            palette.hide()
            return true
        }
    }

    private func spec(for page: Page, session: String) -> PalettePageSpec {
        let wire = page.model
        var spec = PalettePageSpec(
            id: "projectPalette.\(wire.page.rawValue)",
            title: wire.scope?.label ?? wire.title,
            placeholder: wire.placeholder,
            symbol: wire.scope?.icon.symbol ?? "folder.badge.plus",
            providers: [],
            initialQuery: wire.query,
            onCancel: { [weak self, weak page] in
                guard let self, let page else { return }
                self.left(page, session: session)
            },
            queryResults: { [weak self, weak page] query in
                guard let self, let page else { return AsyncStream { $0.finish() } }
                return self.results(for: page, query: query, session: session)
            },
            scope: wire.page == .add ? .root : nil
        )
        spec.usesScopeShortcuts = false
        spec.onActivationInput = { [weak self, weak page] in
            page?.activationEvent = self?.activationEvent()
        }
        return spec
    }

    private func results(for page: Page, query: String, session: String) -> AsyncStream<[PaletteItem]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [PaletteItem].self, bufferingPolicy: .bufferingNewest(1))
        page.waiting?.answer.finish()
        page.waiting = nil
        if page.query != query {
            page.query = query
            view?.sendProjectPaletteEvent(.query(page.model.page, query), session: session)
        }
        if page.model.query == query {
            answer(continuation, for: page)
        } else {
            page.waiting = (query, continuation)
        }
        return stream
    }

    private func answer(_ continuation: AsyncStream<[PaletteItem]>.Continuation, for page: Page) {
        let model = page.model
        let items = model.rows.map { row in
            var item = PaletteItem(
                id: row.id, title: row.label, accessory: row.status, symbol: row.icon?.symbol, isEnabled: row.enabled,
                primary: PaletteCommand(id: row.id, title: row.label, usesSpaceToActivate: false, effect: .performKeepingOpen { [weak self, weak page] in
                    guard let self, let page, pages.last === page, page.query == model.query,
                          page.model.rows.contains(row), let session,
                          let event = row.activation(in: model.page, query: model.query) else { return }
                    let input = page.activationEvent
                    page.activationEvent = nil
                    view?.sendProjectPaletteEvent(event, session: session, input: input)
                })
            )
            item.frecencyKey = nil
            return item
        }
        continuation.yield(items)
        continuation.finish()
    }

    private func activationEvent() -> NSEvent? {
        guard let event = NSApp.currentEvent, let panel = controller()?.visiblePanel, event.window === panel,
              event.type == .keyDown || event.type == .leftMouseDown || event.type == .leftMouseUp else { return nil }
        return event
    }

    private func left(_ page: Page, session: String) {
        guard self.session == session, let palette = controller() else { return }
        if page === pages.first {
            self.session = nil
            rootLevel = nil
            for page in pages { page.waiting?.answer.finish() }
            pages = []
            view?.sendProjectPaletteEvent(.closed, session: session)
            return
        }

        let nav = palette.model.nav
        guard palette.isVisible, nav.levels.first?.id == rootLevel, let top = nav.top,
              nav.depth < pages.count else { return }
        for child in pages.suffix(from: nav.depth) { child.waiting?.answer.finish() }
        pages.removeLast(pages.count - nav.depth)
        if let parent = pages.last {
            view?.sendProjectPaletteEvent(.back(parent.model.page, top.query), session: session)
        }
    }

    @MainActor
    private final class Page {
        var model: AgentProjectPalettePage
        var query: String
        var waiting: (query: String, answer: AsyncStream<[PaletteItem]>.Continuation)?
        var activationEvent: NSEvent?

        init(_ model: AgentProjectPalettePage) {
            self.model = model
            query = model.query
        }
    }
}

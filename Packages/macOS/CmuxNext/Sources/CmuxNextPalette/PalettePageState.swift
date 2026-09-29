

/// Per-page state kept on the navigation stack.
final class PageState {
    enum Kind {
        case list(PalettePageSpec)
        case textInput(PaletteTextInputSpec)
    }

    let kind: Kind
    var query = ""
    var selectedRowID: String?
    var providerItems: [String: [PaletteItem]] = [:]
    var pendingProviders = Set<String>()
    var tasks: [Task<Void, Never>] = []
    private var cachedIndex: PaletteSearchIndex?

    init(kind: Kind) {
        self.kind = kind
    }

    var title: String {
        switch kind {
        case .list(let page): page.title
        case .textInput(let spec): spec.title
        }
    }

    func invalidateIndex() {
        cachedIndex = nil
    }

    func index(for page: PalettePageSpec) -> PaletteSearchIndex {
        if let cachedIndex { return cachedIndex }
        var items: [PaletteItem] = []
        var visible: [Bool] = []
        var seen = Set<String>()
        for provider in page.providers {
            for item in providerItems[provider.id] ?? [] where seen.insert(item.id).inserted {
                items.append(item)
                visible.append(provider.showsItemsForEmptyQuery)
            }
        }
        let index = PaletteSearchIndex(items: items, visibleWhenQueryEmpty: visible)
        cachedIndex = index
        return index
    }

    func cancel() {
        for task in tasks { task.cancel() }
        tasks = []
    }
}

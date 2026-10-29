import AppKit
import CmuxNextWakeups

/// The rows a link or path menu draws before Launch Services answers: each such row says what it
/// waits for (``LinkMenuRow/Waiting``), and its menu item fills in when the system lane answers, in an open menu too.
extension LinkMenu {
    /// The disabled row a submenu shows until its apps land.
    static var loadingRow: LinkMenuRow { LinkMenuRow(.loading, Strings.loading) }

    /// The question for the browsers of `url`'s scheme (http and https share one list); nil without a scheme.
    static func browsersQuery(for url: URL) -> WorkspaceQuery<[URL]>? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        return browsers(scheme: scheme == "https" ? "http" : scheme, own: Bundle.main.bundleURL)
    }

    /// The kept answer to `query`; on a miss nil, and the question goes to the system lane at user-blocking (a
    /// person has the menu open), so the next menu has it.
    func kept<Value>(_ query: WorkspaceQuery<Value>) -> Value? {
        guard let queries else { return nil }
        if let value = queries.cached(query) { return value }
        queries.prefetch([query], priority: .userBlocking)
        return nil
    }

    /// Open With ▸ from the kept answers. When the file's default or its type's apps are not kept yet, the row waits
    /// for them, and without the type's apps it starts with the Loading row.
    func keptOpenWithRow(for file: URL, isDirectory: Bool) -> LinkMenuRow {
        let type = Self.contentType(of: file, isDirectory: isDirectory)
        let first = kept(WorkspaceQuery<URL?>.defaultApplication(toOpen: file))
        let apps = kept(WorkspaceQuery<[URL]>.applications(toOpen: type))
        var row = Self.openWithRow(apps: Self.ordered(apps ?? [], first: first ?? nil, excluding: nil))
        guard queries != nil, first == nil || apps == nil else { return row }
        row.waiting = .apps(file, isDirectory: isDirectory)
        if apps == nil { row.children.insert(Self.loadingRow, at: 0) }
        return row
    }

    /// Fills `item` in when the answers its row waits for land on the system lane, in an open menu too: a submenu
    /// gets its apps (the Loading row goes), and Open In or Open in Text Editor leaves the menu when no app answers.
    func fill(_ item: NSMenuItem, waiting: LinkMenuRow.Waiting, link: URL?, file: URL?) {
        guard let queries else { return }
        switch waiting {
        case .browsers(let url):
            guard let query = Self.browsersQuery(for: url) else { return }
            queries.value(query, priority: .userBlocking) { [weak item] browsers in
                guard let item else { return }
                refill(item, with: linkRows(for: url, browsers: browsers).first { $0.kind == .openIn }, link: link, file: file)
            }
        case .apps(let target, let isDirectory):
            let refresh: @MainActor () -> Void = { [weak item] in
                guard let item else { return }
                refill(item, with: keptOpenWithRow(for: target, isDirectory: isDirectory), link: link, file: file)
            }
            let type = Self.contentType(of: target, isDirectory: isDirectory)
            queries.value(WorkspaceQuery<URL?>.defaultApplication(toOpen: target), priority: .userBlocking) { _ in refresh() }
            queries.value(WorkspaceQuery<[URL]>.applications(toOpen: type), priority: .userBlocking) { _ in refresh() }
        case .editor:
            queries.value(Self.textEditor(setting: router.textEditor()), priority: .userBlocking) { [weak item] editor in
                if editor == nil, let item { item.menu?.removeItem(item) }
            }
        }
    }

    /// Puts `row`'s children in `item`'s submenu; nil `row` (no app answers) takes `item` out of its menu.
    private func refill(_ item: NSMenuItem, with row: LinkMenuRow?, link: URL?, file: URL?) {
        guard let row else {
            item.menu?.removeItem(item)
            return
        }
        guard let submenu = item.submenu else { return }
        submenu.removeAllItems()
        let filled = items(row.children, link: link, file: file)
        (filledItems?(filled) ?? filled).forEach(submenu.addItem)
    }
}

/// What one dropdown row shows: its symbol, title, detail and trailing hint.
nonisolated struct NativeNewTabRowContent: Equatable {
    var symbol: String
    var title: String
    var detail: String?
    var hint: String?

    init(_ row: NativeNewTabRow, strings: NativeNewTabStrings) {
        switch row {
        case .ask(let text): (symbol, title, detail, hint) = ("bubble.left", strings.ask(text), nil, "↩")
        case .run(let text): (symbol, title, detail, hint) = ("terminal", strings.run(text), nil, "↩")
        case .open(let text): (symbol, title, detail, hint) = ("globe", strings.open(text), nil, "↩")
        case .tab(let tab):
            symbol = tab.kind == .terminal ? "terminal" : tab.kind == .browser ? "globe" : "bubble.left"
            (title, detail, hint) = (tab.title, [tab.workspace, tab.detail].compactMap { $0 }.joined(separator: " · "), strings.switchToTab)
        case .workspace(let workspace): (symbol, title, detail, hint) = ("square.stack", workspace.name, workspace.detail, strings.workspace)
        case .page(let page): (symbol, title, detail, hint) = ("clock", page.title ?? page.url, page.title == nil ? nil : page.url, nil)
        case .action(let action):
            (symbol, title, detail) = ("command", action.title, action.detail)
            hint = action.keycaps.map { $0.joined() } ?? strings.command
        }
        if detail?.isEmpty == true { detail = nil }
    }
}

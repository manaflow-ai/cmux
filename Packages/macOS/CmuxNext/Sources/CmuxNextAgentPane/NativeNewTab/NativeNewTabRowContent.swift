/// What one dropdown row shows: its symbol, title, detail and trailing hint.
nonisolated struct NativeNewTabRowContent: Equatable {
    var symbol: String
    var title: String
    var detail: String?
    var hint: String?
    var icon: String?

    init(_ row: NativeNewTabRow, strings: NativeNewTabStrings, home: String? = nil) {
        switch row {
        case .ask(let text): (symbol, title, detail, hint, icon) = ("bubble.left", strings.ask(text), nil, "↩", nil)
        case .run(let text): (symbol, title, detail, hint, icon) = ("terminal", strings.run(text), nil, "↩", nil)
        case .open(let text): (symbol, title, detail, hint, icon) = ("globe", strings.open(text), nil, "↩", nil)
        case .tab(let tab):
            symbol = tab.kind == .terminal ? "terminal" : tab.kind == .browser ? "globe" : "bubble.left"
            (title, detail, hint, icon) = (tab.title,
                                           [tab.workspace, tab.detail].compactMap { $0 }.joined(separator: " · "),
                                           strings.switchToTab, tab.kind == .browser ? tab.icon : nil)
        case .workspace(let workspace): (symbol, title, detail, hint, icon) = ("square.stack", workspace.name, workspace.detail, strings.workspace, nil)
        case .page(let page): (symbol, title, detail, hint, icon) = ("globe", page.title ?? page.url, page.title == nil ? nil : page.url, nil, page.icon)
        case .bookmark(let page): (symbol, title, detail, hint, icon) = ("globe", page.title ?? page.url, page.title == nil ? nil : page.url, nil, page.icon)
        case .action(let action):
            (symbol, title, detail, icon) = ("command", action.title, action.detail, nil)
            hint = action.keycaps.map { $0.joined() } ?? strings.command
        case .chat(let chat):
            (symbol, title, detail, hint, icon) = ("bubble.left.and.bubble.right", chat.title ?? chat.key, NativeNewTabSources.agentName(chat.harness), strings.openChat, nil)
        case .start(let start):
            (symbol, title, detail, hint, icon) = ("folder", strings.start(start.agent, NativeNewTabSources.shown(start.folder, home: home)), nil, strings.startHint, nil)
        }
        if detail?.isEmpty == true { detail = nil }
    }
}

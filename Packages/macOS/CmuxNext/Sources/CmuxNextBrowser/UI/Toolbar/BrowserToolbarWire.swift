public import Foundation

/// The browser toolbar page's wire (webviews/src/browser-chrome/toolbar/wire.ts): the commands the
/// toolbar page (`cmux.browser-toolbar.command`) and the suggestion popup page
/// (`cmux.omnibox-popup.command`) send, the omnibar effects they carry, and the JSON shapes of rows,
/// keys and buttons both ways. Plain Foundation JSON, as ``PageInfoModel/wireState``.
public nonisolated enum BrowserToolbarPageCommand: Equatable, Sendable {
    case goBack, goForward, reload, stop
    /// Right-click on Back, Forward (the history menu under the button) or Reload (its menu).
    case navigationMenu(ToolbarNavigationButton)
    case pageInfo
    case bookmark
    case toolbarButton(BrowserToolbarButton)
    case extensionAction(String)
    case extensionContextMenu(String)
    case extensionsMenu
    /// The crashed-extensions warning button: reload every crashed extension.
    case reloadCrashedExtensions
    case moveExtension(String, index: Int)
    case focusModeBadge, profileBadge, machineBadge
    /// The pointer went down on the field: the web view takes the keys.
    case requestFocus
    case effect(OmnibarPageEffect)
    case status(OmnibarStatus)
    case popup(rows: [BrowserSuggestion], highlighted: Int?, upward: Bool)
    case layout(BrowserToolbarLayoutReport)
    case ack(Int)

    /// A command the toolbar page sent (`{type, ...}`); nil for one it may not send.
    public init?(wire: [String: Any]) {
        switch wire["type"] as? String {
        case "goBack": self = .goBack
        case "goForward": self = .goForward
        case "reload": self = .reload
        case "stop": self = .stop
        case "navigationMenu":
            guard let button = (wire["direction"] as? String).flatMap(ToolbarNavigationButton.init(rawValue:)) else { return nil }
            self = .navigationMenu(button)
        case "pageInfo": self = .pageInfo
        case "bookmark": self = .bookmark
        case "toolbarButton":
            guard let button = (wire["button"] as? String).flatMap(BrowserToolbarButton.init(rawValue:)) else { return nil }
            self = .toolbarButton(button)
        case "extensionAction":
            guard let id = wire["id"] as? String else { return nil }
            self = .extensionAction(id)
        case "extensionContextMenu":
            guard let id = wire["id"] as? String else { return nil }
            self = .extensionContextMenu(id)
        case "extensionsMenu": self = .extensionsMenu
        case "reloadCrashedExtensions": self = .reloadCrashedExtensions
        case "moveExtension":
            guard let id = wire["id"] as? String, let index = Self.int(wire["index"]) else { return nil }
            self = .moveExtension(id, index: index)
        case "focusModeBadge": self = .focusModeBadge
        case "profileBadge": self = .profileBadge
        case "machineBadge": self = .machineBadge
        case "requestFocus": self = .requestFocus
        case "effect":
            guard let effect = (wire["effect"] as? [String: Any]).flatMap(OmnibarPageEffect.init(wire:)) else { return nil }
            self = .effect(effect)
        case "status": self = .status(OmnibarStatus(wire: wire))
        case "popup":
            let rows = (wire["rows"] as? [[String: Any]] ?? []).compactMap(BrowserSuggestion.init(wire:))
            self = .popup(rows: rows, highlighted: Self.int(wire["highlighted"]), upward: wire["upward"] as? Bool ?? false)
        case "layout": self = .layout(BrowserToolbarLayoutReport(wire: wire))
        case "ack":
            guard let seq = Self.int(wire["seq"]) else { return nil }
            self = .ack(seq)
        default: return nil
        }
    }

    static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }

    /// Commands that never act on the shown tab, run from any binding (`isTabIndependent` in wire.ts):
    /// the ack, the layout, and effects that touch only the profile or the Mac.
    var isTabIndependent: Bool {
        switch self {
        case .ack, .layout: true
        case .effect(let effect):
            switch effect {
            case .cancelQuery, .beep, .copyAnswer, .hostTypoFixed, .deleteSuggestion: true
            default: false
            }
        default: false
        }
    }
}

/// Back, Forward and Reload: the buttons with a menu on a right click.
public nonisolated enum ToolbarNavigationButton: String, Equatable, Sendable {
    case back, forward, reload
}

/// The omnibar reducer's effects (`OmnibarEffect` in omnibox/types.ts), which the host runs.
public nonisolated enum OmnibarPageEffect: Equatable, Sendable {
    case query(generation: UInt64, text: String)
    case cancelQuery
    case beep
    case began
    case ended(OmnibarEndReason)
    case deleteSuggestion(URL)
    case typedNavigation(URL)
    case typedHTTPSUpgrade(URL)
    case hostTypoFixed(String)
    case copyAnswer(String)
    case keywordStarted(String)
    case keywordInput(extensionID: String, text: String, generation: UInt64)
    case keywordEnded(String)

    public init?(wire: [String: Any]) {
        let url = (wire["url"] as? String).flatMap(URL.init(string:))
        let generation = (wire["generation"] as? NSNumber)?.uint64Value
        switch wire["type"] as? String {
        case "query":
            guard let generation, let text = wire["text"] as? String else { return nil }
            self = .query(generation: generation, text: text)
        case "cancelQuery": self = .cancelQuery
        case "beep": self = .beep
        case "began": self = .began
        case "ended":
            guard let reason = (wire["reason"] as? [String: Any]).flatMap(OmnibarEndReason.init(wire:)) else { return nil }
            self = .ended(reason)
        case "deleteSuggestion":
            guard let url else { return nil }
            self = .deleteSuggestion(url)
        case "typedNavigation":
            guard let url else { return nil }
            self = .typedNavigation(url)
        case "typedHTTPSUpgrade":
            guard let url else { return nil }
            self = .typedHTTPSUpgrade(url)
        case "hostTypoFixed":
            guard let host = wire["typedHost"] as? String else { return nil }
            self = .hostTypoFixed(host)
        case "copyAnswer":
            guard let text = wire["text"] as? String else { return nil }
            self = .copyAnswer(text)
        case "keywordStarted":
            guard let id = wire["extensionID"] as? String else { return nil }
            self = .keywordStarted(id)
        case "keywordInput":
            guard let id = wire["extensionID"] as? String, let text = wire["text"] as? String, let generation else { return nil }
            self = .keywordInput(extensionID: id, text: text, generation: generation)
        case "keywordEnded":
            guard let id = wire["extensionID"] as? String else { return nil }
            self = .keywordEnded(id)
        default: return nil
        }
    }
}

extension OmnibarEndReason {
    /// `OmnibarEndReason` in omnibox/types.ts.
    public nonisolated init?(wire: [String: Any]) {
        let url = (wire["url"] as? String).flatMap(URL.init(string:))
        let disposition = (wire["disposition"] as? String).flatMap(OmnibarDisposition.init(rawValue:)) ?? .currentTab
        switch wire["kind"] as? String {
        case "commit":
            guard let url else { return nil }
            self = .commit(url)
        case "open":
            guard let url else { return nil }
            self = .open(url, disposition)
        case "cancel": self = .cancel
        case "blur": self = .blur
        case "keyword":
            guard let id = wire["extensionID"] as? String, let text = wire["text"] as? String else { return nil }
            self = .keyword(extensionID: id, text: text, disposition: disposition)
        case "switchToTab":
            guard let key = wire["key"] as? String else { return nil }
            self = .switchToTab(key: key)
        default: return nil
        }
    }
}

/// The omnibar as the toolbar page reported it last: the App reads it synchronously (an action's
/// enabled state, the key router's context, `debug.omnibar`).
public nonisolated struct OmnibarStatus: Equatable, Sendable {
    public var phase = "idle"
    /// True from focus until commit, cancel or blur.
    public var isEditing = false
    /// The suggestion card is open.
    public var isPopupOpen = false
    /// What the field shows now.
    public var text = ""
    public var selection: NSRange?
    public var elided = false
    public var rows: [String] = []
    public var highlighted: Int?
    /// The tab slot this status describes (it may lag the slot just pushed by a pass).
    public var tab: String?
    /// What that tab would leave unsent if it left now; it moves with the tab to another pane.
    public var draft: OmnibarDraft?

    public init() {}

    init(wire: [String: Any]) {
        phase = wire["phase"] as? String ?? "idle"
        isEditing = wire["editing"] as? Bool ?? false
        isPopupOpen = wire["popupOpen"] as? Bool ?? false
        text = wire["text"] as? String ?? ""
        if let pair = wire["selection"] as? [NSNumber], pair.count == 2 {
            selection = NSRange(location: pair[0].intValue, length: pair[1].intValue)
        }
        elided = wire["elided"] as? Bool ?? false
        rows = wire["rows"] as? [String] ?? []
        highlighted = BrowserToolbarPageCommand.int(wire["highlighted"])
        tab = wire["tab"] as? String
        draft = (wire["draft"] as? [String: Any]).flatMap(OmnibarDraft.init(wire:))
    }
}

/// Text a tab left in its omnibar unsent, with its selection (`OmnibarDraft` in wire.ts). The host
/// keeps it on the tab (`BrowserChromeTabState.omnibarDraft`), so a tab that moves to another pane
/// brings it to that pane's toolbar page.
public nonisolated struct OmnibarDraft: Equatable, Sendable {
    public var text: String
    public var selection: NSRange

    public init(text: String, selection: NSRange) {
        self.text = text
        self.selection = selection
    }

    init?(wire: [String: Any]) {
        guard let text = wire["text"] as? String, !text.isEmpty else { return nil }
        let pair = wire["selection"] as? [NSNumber] ?? []
        let selection = pair.count == 2 ? NSRange(location: pair[0].intValue, length: pair[1].intValue) : NSRange(location: text.utf16.count, length: 0)
        self.init(text: text, selection: selection)
    }

    var wire: [String: Any] { ["text": text, "selection": [selection.location, selection.length]] }
}

/// Where the toolbar page drew its controls (`layout` command), in the web view's top-left points.
public nonisolated struct BrowserToolbarLayoutReport: Equatable, Sendable {
    public var rects: [String: CGRect] = [:]
    public var showsForward = true
    public var visiblePinned = 0
    public var collapse = 0

    public init() {}

    init(wire: [String: Any]) {
        for (key, value) in wire["rects"] as? [String: [NSNumber]] ?? [:] where value.count == 4 {
            rects[key] = CGRect(x: value[0].doubleValue, y: value[1].doubleValue, width: value[2].doubleValue, height: value[3].doubleValue)
        }
        showsForward = wire["showsForward"] as? Bool ?? true
        visiblePinned = BrowserToolbarPageCommand.int(wire["visiblePinned"]) ?? 0
        collapse = BrowserToolbarPageCommand.int(wire["collapse"]) ?? 0
    }
}

/// The popup page's commands (`cmux.omnibox-popup.command`).
public nonisolated enum OmniboxPopupCommand: Equatable, Sendable {
    case hover(Int?, pointer: CGPoint)
    case pick(Int, meta: Bool, shift: Bool, alt: Bool)

    /// The popup state revision the page drew the row under (`PopupPageCommand.revision`).
    static func revision(_ wire: [String: Any]) -> Int? { BrowserToolbarPageCommand.int(wire["revision"]) }

    public init?(wire: [String: Any]) {
        switch wire["type"] as? String {
        case "hover":
            let pointer = wire["pointer"] as? [String: Any]
            let x = (pointer?["x"] as? NSNumber)?.doubleValue ?? 0, y = (pointer?["y"] as? NSNumber)?.doubleValue ?? 0
            self = .hover(BrowserToolbarPageCommand.int(wire["index"]), pointer: CGPoint(x: x, y: y))
        case "pick":
            guard let index = BrowserToolbarPageCommand.int(wire["index"]) else { return nil }
            let modifiers = wire["modifiers"] as? [String: Any]
            self = .pick(index, meta: modifiers?["meta"] as? Bool ?? false, shift: modifiers?["shift"] as? Bool ?? false,
                         alt: modifiers?["alt"] as? Bool ?? false)
        default: return nil
        }
    }
}

extension BrowserSuggestion.Kind {
    /// The kind's name on the wire (`SuggestionKind`).
    nonisolated var wire: String {
        switch self {
        case .navigate: "navigate"
        case .search: "search"
        case .history: "history"
        case .bookmark: "bookmark"
        case .keyword: "keyword"
        case .switchToTab: "switchToTab"
        case .answer: "answer"
        }
    }

    nonisolated init?(wire: String) {
        switch wire {
        case "navigate": self = .navigate
        case "search": self = .search
        case "history": self = .history
        case "bookmark": self = .bookmark
        case "keyword": self = .keyword
        case "switchToTab": self = .switchToTab
        case "answer": self = .answer
        default: return nil
        }
    }

    /// Rows that name a known web page, whose site icon the popup shows.
    var showsSiteIcon: Bool { self == .history || self == .bookmark || self == .switchToTab }
}

extension BrowserSuggestion {
    /// The row as the page's `BrowserSuggestion`.
    nonisolated var wire: [String: Any] {
        var row: [String: Any] = ["kind": kind.wire, "title": title, "detail": detail, "url": url.absoluteString, "score": score,
                                  "inlineCompletable": inlineCompletable]
        if let content { row["content"] = content }
        if let tabKey { row["tabKey"] = tabKey }
        return row
    }

    nonisolated init?(wire: [String: Any]) {
        guard let kind = (wire["kind"] as? String).flatMap(Kind.init(wire:)), let url = (wire["url"] as? String).flatMap(URL.init(string:)) else { return nil }
        self.init(kind: kind, title: wire["title"] as? String ?? "", detail: wire["detail"] as? String ?? "", url: url,
                  score: (wire["score"] as? NSNumber)?.doubleValue ?? 0)
        content = wire["content"] as? String
        inlineCompletable = wire["inlineCompletable"] as? Bool ?? true
        tabKey = wire["tabKey"] as? String
    }
}

extension BrowserSearchEngine {
    var wire: [String: Any] {
        var engine: [String: Any] = ["id": id, "name": name, "queryTemplate": queryTemplate]
        if let suggestTemplate { engine["suggestTemplate"] = suggestTemplate }
        return engine
    }
}

extension OmnibarKeyword {
    var wire: [String: Any] {
        var keyword: [String: Any] = ["extensionID": extensionID, "keyword": keyword, "name": name]
        if let defaultDescription { keyword["defaultDescription"] = defaultDescription }
        if let searchEngine { keyword["searchEngine"] = searchEngine.wire }
        return keyword
    }
}

extension BrowserToolbarButtonState {
    /// A resolved trailing button (`WireToolbarButton`).
    func wire(_ button: BrowserToolbarButton, pressed: Bool) -> [String: Any] {
        var wire: [String: Any] = [
            "id": button.rawValue, "icon": icon.rawValue, "label": label, "enabled": isEnabled, "active": isActive,
            "tooltip": showsToolTip, "opensMenu": button.opensMenu, "pressed": pressed,
            "collapseLevel": button.collapseLevel.map { $0 as Any } ?? NSNull(),
        ]
        if let progress { wire["progress"] = progress }
        return wire
    }
}

/// One-shot host requests to the toolbar page (`ToolbarHostEvent`).
nonisolated enum BrowserToolbarHostEvent {
    static func focus(_ source: String) -> [String: Any] { ["kind": "focus", "source": source] }
    static var blur: [String: Any] { ["kind": "blur"] }
    static func key(_ key: [String: Any]) -> [String: Any] { ["kind": "key", "key": key] }
    static func enter(_ disposition: OmnibarDisposition) -> [String: Any] { key(["kind": "enter", "disposition": disposition.rawValue]) }
    static var focusLocation: [String: Any] { key(["kind": "focusLocation"]) }
    static var searchWithDefaultEngine: [String: Any] { key(["kind": "searchWithDefaultEngine"]) }
    static func suggestions(_ generation: UInt64, _ rows: [BrowserSuggestion]) -> [String: Any] {
        ["kind": "suggestions", "generation": generation, "rows": rows.map(\.wire)]
    }
    static func moreSuggestions(_ generation: UInt64, _ rows: [BrowserSuggestion], capacity: Int) -> [String: Any] {
        ["kind": "moreSuggestions", "generation": generation, "rows": rows.map(\.wire), "capacity": capacity]
    }
    static func rowHover(_ row: Int?, pointer: CGPoint) -> [String: Any] {
        ["kind": "rowHover", "row": row.map { $0 as Any } ?? NSNull(), "pointer": ["x": pointer.x, "y": pointer.y]]
    }
    /// `shown`: the row the card drew at `row` when it was clicked. The page's rows can change in the
    /// same push (a pending query's results), so the page opens that row or nothing, never its neighbor.
    static func rowClick(_ row: Int, shown: BrowserSuggestion?, meta: Bool, shift: Bool, alt: Bool) -> [String: Any] {
        var event: [String: Any] = ["kind": "rowClick", "row": row, "modifiers": ["meta": meta, "shift": shift, "alt": alt]]
        if let shown { event["shown"] = ["kind": shown.kind.wire, "url": shown.url.absoluteString] }
        return event
    }
    static var showPageURL: [String: Any] { ["kind": "showPageURL"] }
    static func pasteAndGo(_ text: String) -> [String: Any] { ["kind": "pasteAndGo", "text": text] }
    static func dropped(_ text: String) -> [String: Any] { ["kind": "dropped", "text": text] }
    static func forgetTab(_ tab: String) -> [String: Any] { ["kind": "forgetTab", "tab": tab] }
    static func debugType(_ text: String, commit: Bool) -> [String: Any] { ["kind": "debugType", "text": text, "commit": commit] }
}

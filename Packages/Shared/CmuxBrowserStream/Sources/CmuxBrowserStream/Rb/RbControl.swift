public import CmuxMobileWire

/// The `cmux.rb/1` control messages a phone browser stream uses
/// (cmux-remote-browser `proto.rs`; `schemas/remote-tab/messages.json`).
/// Every other message decodes as `.unmodeled` and is kept as sent.
public enum RbControl: Hashable, Sendable {
    case state(RbSessionState)
    case visibility(visible: Bool)
    case screen(seq: UInt32, screen: RbScreenInfo)
    case screenApplied(seq: UInt32, pixelWidth: UInt32, pixelHeight: UInt32, scale: Double)
    case page(RbPage)
    case history(RbHistoryOp)
    case keyUnhandled(inputSeq: UInt32)
    case cursor(RbCursorShape)
    case textInput(inputType: String, compositionRects: [RbRect], caret: RbRect?)
    case menuShow(token: UInt64, menu: JSONValue)
    case menuResult(token: UInt64, choice: RbMenuChoice)
    case dialogShow(token: UInt64, dialog: JSONValue)
    case dialogResult(token: UInt64, accept: Bool, text: String?)
    case clipboardPush(seq: UInt32, items: [RbClipboardItem])
    case clipboardWrite(items: [RbClipboardItem])
    case openTab(request: UInt64, url: String, disposition: String, userGesture: Bool)
    case openTabResult(request: UInt64, tab: String?, refused: String?)
    /// Loads a URL in the page (cap `navigate`, added by C2).
    case navigate(request: UInt64, url: String)
    case navigateResult(request: UInt64, refused: RbNavigateRefusal?)
    case close
    case closed(reason: String)
    case unmodeled(JSONValue)

    public init(json: JSONValue) throws(RdWireError) {
        let r = try RbJSONReader(json)
        let tag = try r.string("t")
        switch tag {
        case "rb.state":
            guard let state = RbSessionState(rawValue: try r.string("state")) else { throw RdWireError("state") }
            self = .state(state)
        case "rb.visibility": self = .visibility(visible: try r.bool("visible"))
        case "rb.screen": self = .screen(seq: try r.uint32("seq"), screen: try RbScreenInfo(json: try r.value("screen")))
        case "rb.screen_applied":
            self = .screenApplied(seq: try r.uint32("seq"), pixelWidth: try r.uint32("pixel_width"),
                                  pixelHeight: try r.uint32("pixel_height"), scale: try r.double("scale"))
        case "rb.page": self = .page(try RbPage(reader: r))
        case "rb.history":
            guard let op = RbHistoryOp(rawValue: try r.string("op")) else { throw RdWireError("history op") }
            self = .history(op)
        case "rb.key_unhandled": self = .keyUnhandled(inputSeq: try r.uint32("input_seq"))
        case "rb.cursor": self = .cursor(try RbCursorShape(json: try r.value("cursor")))
        case "rb.text_input":
            var rects: [RbRect] = []
            for rect in try r.array("composition_rects") { rects.append(try RbRect(json: rect)) }
            self = .textInput(inputType: try r.string("input_type"), compositionRects: rects,
                              caret: r.isNull("caret") ? nil : try RbRect(json: try r.value("caret")))
        case "rb.menu.show": self = .menuShow(token: try r.uint64("token"), menu: try r.value("menu"))
        case "rb.menu.result": self = .menuResult(token: try r.uint64("token"), choice: try RbMenuChoice(json: try r.value("choice")))
        case "rb.dialog.show": self = .dialogShow(token: try r.uint64("token"), dialog: try r.value("dialog"))
        case "rb.dialog.result":
            self = .dialogResult(token: try r.uint64("token"), accept: try r.bool("accept"), text: r.optionalString("text"))
        case "rb.clipboard.push": self = .clipboardPush(seq: try r.uint32("seq"), items: try Self.items(r))
        case "rb.clipboard.write": self = .clipboardWrite(items: try Self.items(r))
        case "rb.open_tab":
            self = .openTab(request: try r.uint64("request"), url: try r.string("url"),
                            disposition: try r.string("disposition"), userGesture: try r.bool("user_gesture"))
        case "rb.open_tab.result":
            self = .openTabResult(request: try r.uint64("request"), tab: r.optionalString("tab"), refused: r.optionalString("refused"))
        case "rb.navigate":
            // The original rb/1 vector carried a URL-only navigate message;
            // C2 added a request id so the host can answer asynchronously.
            // Preserve the legacy shape verbatim until all peers speak C2.
            if let request = try r.optionalUInt64("request") {
                self = .navigate(request: request, url: try r.string("url"))
            } else {
                self = .unmodeled(json)
            }
        case "rb.navigate.result":
            let refused: RbNavigateRefusal?
            if r.isNull("refused") {
                refused = nil
            } else {
                guard let value = RbNavigateRefusal(rawValue: try r.string("refused")) else { throw RdWireError("refused") }
                refused = value
            }
            self = .navigateResult(request: try r.uint64("request"), refused: refused)
        case "rb.close": self = .close
        case "rb.closed": self = .closed(reason: try r.string("reason"))
        default:
            guard tag.hasPrefix("rb.") else { throw RdWireError("not an rb message: \(tag)") }
            self = .unmodeled(json)
        }
    }

    public var jsonValue: JSONValue {
        if case .unmodeled(let value) = self { return value }
        var object = fields
        object["t"] = .string(tag)
        return .object(object)
    }

    private var tag: String {
        switch self {
        case .state: "rb.state"
        case .visibility: "rb.visibility"
        case .screen: "rb.screen"
        case .screenApplied: "rb.screen_applied"
        case .page: "rb.page"
        case .history: "rb.history"
        case .keyUnhandled: "rb.key_unhandled"
        case .cursor: "rb.cursor"
        case .textInput: "rb.text_input"
        case .menuShow: "rb.menu.show"
        case .menuResult: "rb.menu.result"
        case .dialogShow: "rb.dialog.show"
        case .dialogResult: "rb.dialog.result"
        case .clipboardPush: "rb.clipboard.push"
        case .clipboardWrite: "rb.clipboard.write"
        case .openTab: "rb.open_tab"
        case .openTabResult: "rb.open_tab.result"
        case .navigate: "rb.navigate"
        case .navigateResult: "rb.navigate.result"
        case .close: "rb.close"
        case .closed: "rb.closed"
        case .unmodeled: ""
        }
    }

    private var fields: [String: JSONValue] {
        switch self {
        case .state(let state): ["state": .string(state.rawValue)]
        case .visibility(let visible): ["visible": .bool(visible)]
        case .screen(let seq, let screen): ["seq": .int(Int64(seq)), "screen": screen.jsonValue]
        case .screenApplied(let seq, let width, let height, let scale):
            ["seq": .int(Int64(seq)), "pixel_width": .int(Int64(width)), "pixel_height": .int(Int64(height)),
             "scale": .double(scale)]
        case .page(let page): page.fields
        case .history(let op): ["op": .string(op.rawValue)]
        case .keyUnhandled(let seq): ["input_seq": .int(Int64(seq))]
        case .cursor(let cursor): ["cursor": cursor.jsonValue]
        case .textInput(let type, let rects, let caret):
            ["input_type": .string(type), "composition_rects": .array(rects.map(\.jsonValue)), "caret": caret?.jsonValue ?? .null]
        case .menuShow(let token, let menu): ["token": .int(Int64(token)), "menu": menu]
        case .menuResult(let token, let choice): ["token": .int(Int64(token)), "choice": choice.jsonValue]
        case .dialogShow(let token, let dialog): ["token": .int(Int64(token)), "dialog": dialog]
        case .dialogResult(let token, let accept, let text): ["token": .int(Int64(token)), "accept": .bool(accept), "text": text.rbJSON]
        case .clipboardPush(let seq, let items): ["seq": .int(Int64(seq)), "items": .array(items.map(\.jsonValue))]
        case .clipboardWrite(let items): ["items": .array(items.map(\.jsonValue))]
        case .openTab(let request, let url, let disposition, let gesture):
            ["request": .int(Int64(request)), "url": .string(url), "disposition": .string(disposition),
             "user_gesture": .bool(gesture)]
        case .openTabResult(let request, let tab, let refused):
            ["request": .int(Int64(request)), "tab": tab.rbJSON, "refused": refused.rbJSON]
        case .navigate(let request, let url): ["request": .int(Int64(request)), "url": .string(url)]
        case .navigateResult(let request, let refused): ["request": .int(Int64(request)), "refused": refused.map { .string($0.rawValue) } ?? .null]
        case .close: [:]
        case .closed(let reason): ["reason": .string(reason)]
        case .unmodeled: [:]
        }
    }

    private static func items(_ r: RbJSONReader) throws(RdWireError) -> [RbClipboardItem] {
        var out: [RbClipboardItem] = []
        for item in try r.array("items") { out.append(try RbClipboardItem(json: item)) }
        return out
    }
}

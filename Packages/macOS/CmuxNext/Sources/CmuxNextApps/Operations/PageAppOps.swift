import CmuxNextBrowserCore
public import CmuxNextSettings
import Foundation

/// The `page` family (`cmux.page.*`): reader mode and link hints for extensions, in the browser tabs
/// the app draws (WebKit or CEF), which the daemon cannot script (`browser_rendered_by_app`). Each op
/// runs page scripts through the app's own `browser.page.eval` control method, so a tab is addressed
/// as everywhere else: `tab` is a `tab_…` id (or unique prefix); without it, the focused browser tab
/// of the front window.
///
/// - `page.read {tab?}` (scope `page:read`): ``readerScript``'s main text and links, plus `tab`.
/// - `page.hints {tab?, action: show|clear}` (scope `page:write`, a gesture): `show` labels the
///   clickable elements in view with the built-in link hints' own collect script, labels and drawing
///   (`LinkHintSession`, the `f` key), and answers `{tab, hints: [{label, text, href}]}`; `clear`
///   removes an app's labels (never the built-in `f` session's).
/// - `page.follow {tab?, label, new_split?}` (scope `page:write`, a gesture): clears the labels, then
///   clicks the hint's element with the built-in click script, or opens its link in a new browser
///   split (`browser.link.openInSplit`, what `F` does); `{tab, followed, href}`. `followed` is false
///   when the label is not on screen any more (a scroll, a new page or the built-in `f` replaced it).
///
/// The labels an app drew are kept here per tab (their click points never cross to the app), and
/// the overlay carries a token so a follow never acts on another session's labels.
public nonisolated struct PageAppOps: AppHostCapabilityHandler {
    /// Runs one control method in process (`ControlRouter.appControl`).
    public typealias Control = @Sendable (_ method: String, _ params: [String: JSONValue]) async throws(AppHostCapabilityError) -> JSONValue

    let control: Control
    let board: PageHintBoard

    /// - Parameter control: Runs `browser.page.eval` and `action.run` in process.
    public init(control: @escaping Control) {
        self.control = control
        board = PageHintBoard()
    }

    public var families: Set<String> { ["page"] }

    public func handle(_ request: AppHostCapabilityRequest) async throws(AppHostCapabilityError) -> AppJSON {
        guard request.params == .null || request.params.objectValue != nil else { throw Self.invalid("\(request.op) takes an object") }
        let tab = try Self.tab(request)
        switch request.op {
        case "page.read":
            return try await read(tab: tab)
        case "page.hints":
            switch request.params["action"]?.stringValue {
            case "show": return try await showHints(tab: tab)
            case "clear": return try await clearHints(tab: tab)
            default: throw Self.invalid("page.hints needs action show or clear")
            }
        case "page.follow":
            let label = (request.params["label"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            guard !label.isEmpty, label.count <= 8 else { throw Self.invalid("page.follow needs the label of a shown hint") }
            if let split = request.params["new_split"], split != .null, split.boolValue == nil { throw Self.invalid("new_split is true or false") }
            return try await follow(tab: tab, label: label, newSplit: request.params["new_split"]?.boolValue == true, request: request)
        default:
            throw .unsupported(request.op)
        }
    }

    // MARK: Ops

    private func read(tab: String?) async throws(AppHostCapabilityError) -> AppJSON {
        let (id, value) = try await eval(Self.readerScript, tab: tab)
        guard let json = value.stringValue, case .object(var page)? = try? AppJSON.parse(Data(json.utf8)) else {
            throw Self.failed("the page did not answer the reader script")
        }
        page["tab"] = .string(id)
        return .object(page)
    }

    private func showHints(tab: String?) async throws(AppHostCapabilityError) -> AppJSON {
        let (id, value) = try await eval(LinkHintSession.collectScript, tab: tab)
        let targets = Self.targets(value.stringValue ?? "")
        let labels = LinkHintSession.labels(count: targets.count)
        let hints = zip(labels, targets).map { (label: $0.0, target: $0.1.target, text: $0.1.text) }
        guard !hints.isEmpty else {
            _ = try await eval(Self.clearScript, tab: id)
            await board.set(nil, tab: id)
            return ["tab": .string(id), "hints": []]
        }
        let token = UUID().uuidString
        let draw = LinkHintSession.drawScript(hints.map { (label: $0.label, target: $0.target) })
        let drawn = try await eval(Self.tagged(draw, token: token), tab: id).value
        guard drawn.boolValue == true else { throw Self.failed("the page did not draw the hints") }
        await board.set(PageHintBoard.Shown(token: token, targets: Dictionary(hints.map { ($0.label, $0.target) }, uniquingKeysWith: { first, _ in first })), tab: id)
        return ["tab": .string(id), "hints": .array(hints.map { hint -> AppJSON in
            ["label": .string(hint.label), "text": .string(hint.text), "href": hint.target.href.map { AppJSON.string($0.absoluteString) } ?? AppJSON.null]
        })]
    }

    private func clearHints(tab: String?) async throws(AppHostCapabilityError) -> AppJSON {
        let (id, _) = try await eval(Self.clearScript, tab: tab)
        await board.set(nil, tab: id)
        return ["tab": .string(id), "hints": []]
    }

    private func follow(tab: String?, label: String, newSplit: Bool, request: AppHostCapabilityRequest) async throws(AppHostCapabilityError) -> AppJSON {
        let (id, shownToken) = try await eval(Self.tokenScript, tab: tab)
        let notFollowed: AppJSON = ["tab": .string(id), "followed": false, "href": .null]
        guard let shown = await board.shown(tab: id), shownToken.stringValue == shown.token else {
            // The labels are gone (a scroll, a new page) or are another session's.
            await board.set(nil, tab: id)
            return notFollowed
        }
        guard let target = shown.targets[label] else { return notFollowed }
        let href: AppJSON = target.href.map { AppJSON.string($0.absoluteString) } ?? .null
        if newSplit, target.href == nil { return notFollowed }
        _ = try await eval(LinkHintSession.removeScript, tab: id)
        await board.set(nil, tab: id)
        if newSplit, let url = target.href {
            var params: [String: JSONValue] = [
                "action": "browser.link.openInSplit",
                "args": ["url": .string(url.absoluteString)],
                "target": .string("tab:" + id),
                "origin": .string(request.origin),
            ]
            if let key = request.idempotencyKey { params["idempotency_key"] = .string(key) }
            _ = try await control("action.run", params)
            return ["tab": .string(id), "followed": true, "href": href]
        }
        let clicked = try await eval(LinkHintSession.clickScript(target), tab: id).value
        return ["tab": .string(id), "followed": .bool(clicked.boolValue == true), "href": href]
    }

    // MARK: Page calls

    /// Runs `script` in `tab` (the focused browser tab when nil); answers the tab's full id and the script's value.
    private func eval(_ script: String, tab: String?) async throws(AppHostCapabilityError) -> (tab: String, value: JSONValue) {
        var params: [String: JSONValue] = ["script": .string(script)]
        if let tab { params["tab"] = .string(tab) }
        let reply = try await control("browser.page.eval", params)
        guard let id = reply["tab"]?.stringValue else { throw Self.failed("the browser answered without a tab") }
        return (id, reply["value"] ?? .null)
    }

    /// The overlay `drawScript` makes (`LinkHintSession.overlayTag`).
    static let overlayTag = "cmux-link-hints"

    /// `draw`, then the overlay marked with `token`: an app's labels, told apart from the built-in `f`
    /// session's and from another draw's.
    static func tagged(_ draw: String, token: String) -> String {
        """
        (() => {
          const drawn = \(draw);
          const host = document.querySelector('\(overlayTag)');
          if (!host) return false;
          host.dataset.cmuxApp = \(literal(token));
          return drawn === true;
        })()
        """
    }

    /// The token of the labels on the page, or null (none, or the built-in `f` session's).
    static let tokenScript = "(() => document.querySelector('\(overlayTag)')?.dataset.cmuxApp ?? null)()"

    /// Removes an app's labels; the built-in `f` session's stay.
    static let clearScript = """
    (() => {
      const host = document.querySelector('\(overlayTag)');
      if (!host || !host.dataset.cmuxApp) return false;
      host.remove();
      return true;
    })()
    """

    /// The collect script's targets with the text that names each.
    static func targets(_ json: String) -> [(target: LinkHintTarget, text: String)] {
        nonisolated struct Named: Decodable { var text: String? }
        let data = Data(json.utf8)
        guard let targets = try? JSONDecoder().decode([LinkHintTarget].self, from: data),
              let names = try? JSONDecoder().decode([Named].self, from: data), names.count == targets.count else { return [] }
        return zip(targets, names).map { (target: $0.0, text: $0.1.text ?? "") }
    }

    static func tab(_ request: AppHostCapabilityRequest) throws(AppHostCapabilityError) -> String? {
        guard let raw = request.params["tab"], raw != .null else { return nil }
        guard let tab = raw.stringValue?.trimmingCharacters(in: .whitespaces), !tab.isEmpty, tab.count <= 128 else {
            throw invalid("tab is a tab_… id")
        }
        return tab
    }

    static func literal(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]), let array = String(data: data, encoding: .utf8) else { return "''" }
        return String(array.dropFirst().dropLast())
    }

    static func invalid(_ message: String) -> AppHostCapabilityError { AppHostCapabilityError(code: "invalid_params", message: message) }
    static func failed(_ message: String) -> AppHostCapabilityError { AppHostCapabilityError(code: "operation.failed", message: message, retryable: true) }
}

/// The link-hint labels each tab shows for apps (``PageAppOps``): label to click point, and the token
/// its overlay carries. A bounded number of tabs; the oldest is forgotten first.
actor PageHintBoard {
    nonisolated struct Shown: Sendable {
        var token: String
        var targets: [String: LinkHintTarget]
    }

    nonisolated static let maxTabs = 32
    private var shown: [String: Shown] = [:]
    private var order: [String] = []

    func shown(tab: String) -> Shown? { shown[tab] }

    func set(_ value: Shown?, tab: String) {
        order.removeAll { $0 == tab }
        shown[tab] = value
        guard value != nil else { return }
        order.append(tab)
        while order.count > Self.maxTabs { shown[order.removeFirst()] = nil }
    }
}

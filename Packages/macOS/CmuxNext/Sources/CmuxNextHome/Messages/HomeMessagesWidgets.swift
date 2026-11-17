public import CmuxHomeCore
public import CmuxHomeRender
public import CmuxNextPages
public import CmuxNextSettings
import Foundation

/// Chat widgets on the Messages page (plans/cmux-next/chat-widgets-DESIGN.md section 4; the page
/// draws the card, webviews `cards/widget/WidgetCard.tsx`). Ported from the deleted native
/// transcript's MessagesLabHome `HomeProjection+Widgets.swift` and `HomeWidgetRowProvider.swift`:
/// the page asks for each widget part's snapshot, clicks go back to its scene node, the page names
/// the keys it shows so their mounts live while it does (`keep(_:owner:)`, this provider the owner),
/// and a scene change sends the new snapshot. The mounting, the scene mapping and the app's scopes
/// stay with the host (``HomeWidgetHosting``, the App's `ChatWidgetHost`); without one every op
/// answers nothing and the page draws the fallback text.
///
/// - `widget.snapshot {key, widget: {app, widget, props, fallback, url?}}` -> `{items: [...]}` or
///   null (loading, no app, failed). `key` is `<message id>#<part index>`.
/// - `widget.tap {key, node}`: a click on a row or button (a click only).
/// - `widget.keep {keys}`: the widget keys the page shows; others it kept are released.
/// - stream `widget`: `{key, snapshot}` (snapshot as `widget.snapshot` answers) as a widget changes.
///
/// An item is `{type: "text", text, style, tint}`, `{type: "row", node?, title, subtitle?, symbol?,
/// tint, badge?}`, `{type: "buttons", buttons: [{node, title, prominent, enabled}]}`, `{type:
/// "badge", text, tint}`, `{type: "divider"}` or `{type: "empty", title, message?, symbol?}`.
@MainActor
public final class HomeMessagesWidgets: PageProvider {
    public static let prefix = HomeMessagesPageRoute.prefix + "widget"

    /// The app's widget host, read per call (nil: no app platform, widgets show their fallback).
    private let host: @MainActor () -> (any HomeWidgetHosting)?
    private let personOnlyMessage: String
    /// The part of each key the page asked for: a change maps it again with the same part.
    private var widgets: [String: ChatWidget] = [:]
    /// The keys this page keeps mounted.
    private var kept: Set<String> = []
    private var listeners: [UUID: @MainActor (JSONValue) -> Void] = [:]
    private var watch: Task<Void, Never>?

    /// - Parameters:
    ///   - host: the widget host (the App's `services.sidebarCustomization.chatWidgets`).
    ///   - personOnlyMessage: the refusal a tap that is no click gets.
    public init(host: @escaping @MainActor () -> (any HomeWidgetHosting)?, personOnlyMessage: String) {
        self.host = host
        self.personOnlyMessage = personOnlyMessage
    }

    /// One fixed host.
    public convenience init(host: (any HomeWidgetHosting)?, personOnlyMessage: String) {
        self.init(host: { [weak host] in host }, personOnlyMessage: personOnlyMessage)
    }

    nonisolated deinit {
        watch?.cancel()
    }

    private var owner: ObjectIdentifier { ObjectIdentifier(self) }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        let fields = params.objectValue ?? [:]
        switch op {
        case Self.prefix + ".snapshot":
            guard let key = fields["key"]?.stringValue, !key.isEmpty,
                  let widget = fields["widget"].flatMap(Self.widget) else {
                throw PageError.invalidParams("key and widget must name a widget part")
            }
            guard let host = host() else { return .null }
            widgets[key] = widget
            // Asked for means shown: kept until the page's next keep says otherwise.
            if kept.insert(key).inserted { host.keep(kept, owner: owner) }
            return Self.json(host.snapshot(for: key, widget: widget))
        case Self.prefix + ".tap":
            guard context.userGesture else { throw PageError(code: PageNativeOp.userOnlyCode, message: personOnlyMessage) }
            guard let key = fields["key"]?.stringValue, let node = fields["node"]?.stringValue, !node.isEmpty else {
                throw PageError.invalidParams("key and node must name a widget's item")
            }
            host()?.tap(key: key, node: node)
            return .null
        case Self.prefix + ".keep":
            guard let keys = fields["keys"]?.arrayValue else { throw PageError.invalidParams("keys must be a list") }
            keep(Set(keys.compactMap(\.stringValue)))
            return .null
        default:
            throw PageError.unknownOp(op)
        }
    }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                          onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.prefix else { throw PageError.unknownOp(stream) }
        let id = UUID()
        listeners[id] = onEvent
        startWatch()
        return PageSubscription { [weak self] in
            guard let self else { return }
            listeners[id] = nil
            if listeners.isEmpty { watch?.cancel(); watch = nil }
        }
    }

    /// The page closed: its widgets are released (as the native view's `stopWidgets`).
    public func pageDidClose() {
        keep([])
        watch?.cancel()
        watch = nil
    }

    private func keep(_ keys: Set<String>) {
        kept = keys
        widgets = widgets.filter { keys.contains($0.key) }
        host()?.keep(keys, owner: owner)
    }

    /// One watch of the host's changes while the page listens (native `watchWidgets`).
    private func startWatch() {
        guard watch == nil, let host = host() else { return }
        let changes = host.changes()
        // task-owner: lives while the page listens to `widget` (cancelled with its last listener, at close or deinit); event-driven
        watch = Task { [weak self] in
            for await key in changes {
                self?.changed(key)
            }
        }
    }

    /// Widget `key` changed: the page gets its new snapshot (native `refreshWidget`).
    func changed(_ key: String) {
        guard let widget = widgets[key], let host = host() else { return }
        let event: JSONValue = .object(["key": .string(key), "snapshot": Self.json(host.snapshot(for: key, widget: widget))])
        for listener in listeners.values { listener(event) }
    }

    // MARK: Wire

    /// The page's widget part (`{app, widget, props, fallback, url?}`, the daemon's `Part::Widget`), or nil.
    static func widget(_ value: JSONValue) -> ChatWidget? {
        guard let fields = value.objectValue, let app = fields["app"]?.stringValue, !app.isEmpty,
              let fallback = fields["fallback"]?.stringValue, !fallback.isEmpty else { return nil }
        let props = fields["props"].flatMap { $0.objectValue == nil ? nil : $0.compactText } ?? "{}"
        let name = fields["widget"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "cmux.chat.widget/1"
        return ChatWidget(app: app, widget: name, propsJSON: props, fallback: fallback, url: fields["url"]?.stringValue)
    }

    /// A snapshot as the page reads it (null: draw the fallback); at most ``HomeWidgetSnapshot/maxItems`` items.
    static func json(_ snapshot: HomeWidgetSnapshot?) -> JSONValue {
        guard let snapshot else { return .null }
        return .object(["items": .array(snapshot.items.prefix(HomeWidgetSnapshot.maxItems).map(Self.item))])
    }

    static func item(_ item: HomeWidgetItem) -> JSONValue {
        var fields: [String: JSONValue]
        switch item {
        case let .text(text, style, tint):
            fields = ["type": "text", "text": .string(text), "style": .string(style.rawValue), "tint": .string(tint.rawValue)]
        case let .row(node, title, subtitle, symbol, tint, badge):
            fields = ["type": "row", "title": .string(title), "tint": .string(tint.rawValue)]
            if let node { fields["node"] = .string(node) }
            if let subtitle, !subtitle.isEmpty { fields["subtitle"] = .string(subtitle) }
            if let symbol, !symbol.isEmpty { fields["symbol"] = .string(symbol) }
            if let badge, !badge.isEmpty { fields["badge"] = .string(badge) }
        case let .buttons(buttons):
            fields = ["type": "buttons", "buttons": .array(buttons.map { button in
                .object(["node": .string(button.node), "title": .string(button.title), "prominent": .bool(button.prominent),
                         "enabled": .bool(button.enabled)])
            })]
        case let .badge(text, tint):
            fields = ["type": "badge", "text": .string(text), "tint": .string(tint.rawValue)]
        case .divider:
            fields = ["type": "divider"]
        case let .empty(title, message, symbol):
            fields = ["type": "empty", "title": .string(title)]
            if let message, !message.isEmpty { fields["message"] = .string(message) }
            if let symbol, !symbol.isEmpty { fields["symbol"] = .string(symbol) }
        }
        return .object(fields)
    }
}

import AppKit
import CmuxHomeRender
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextHomeModel
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// The Chat Colors page's ops (`cmux.home.chatColors.*`, webviews/src/pages/home-chat-colors/host.ts).
/// The page owns no data: a pick runs ``HomeChatColorStore/set(_:for:)``, the same code
/// `cmux chat colors` runs, and the `state` stream follows the store and ``DesignSettings`` through
/// Observation, so a change from anywhere (a pick, the CLI, a theme or `home.bubbleColors.*`) redraws
/// the page. One provider serves every open of the one page (``HomeChatColorsService``); each
/// open is a new session, and a call for another session is refused, so a late one never changes
/// a newer chat.
@MainActor
final class HomeChatColorsProvider: PageProvider {
    static let prefix = "cmux.home.chatColors."
    static let sessionStream = prefix + "session"
    static let stateStream = prefix + "state"

    /// One open: the chat the page shows.
    struct Session: Equatable, Sendable {
        /// Echoed by every call.
        let id: String
        let conversation: String
        /// The chat's name, in the panel's title.
        let name: String

        var event: JSONValue { .object(["id": .string(id), "conversation": .string(conversation), "name": .string(name)]) }
    }

    /// The chat's four colours, as the page and the CLI name them.
    enum Role: String, CaseIterable {
        case sent, sentText, received, receivedText

        var key: WritableKeyPath<HomeBubbleColors, HomeColor?> {
            switch self {
            case .sent: \.sent
            case .sentText: \.sentText
            case .received: \.received
            case .receivedText: \.receivedText
            }
        }

        /// The colour the role draws with in `preview`.
        func shown(in preview: HomeChatColorsPreview) -> HomeColor {
            switch self {
            case .sent: preview.sent.fill
            case .sentText: preview.sent.text
            case .received: preview.received.fill
            case .receivedText: preview.received.text
            }
        }
    }

    private let store: HomeChatColorStore
    private let design: DesignSettings
    /// The view whose theme scope the preview resolves in (the panel's content); nil resolves in the app's.
    var themeView: () -> NSView? = { nil }
    /// The open session; nil while the panel is closed.
    private(set) var session: Session?
    private var sessionListener: (@MainActor (JSONValue) -> Void)?
    private var stateListener: (@MainActor (JSONValue) -> Void)?
    /// The loop that streams the open chat's state; one at a time, none while the panel is closed.
    private(set) var following: Task<Void, Never>?

    /// Done, Return or Escape on the page.
    var onDone: (() -> Void)?
    /// Custom Color for `role`, starting from the colour it draws with now.
    var onCustomColor: ((_ role: Role, _ start: HomeColor) -> Void)?

    init(store: HomeChatColorStore, design: DesignSettings) {
        self.store = store
        self.design = design
    }

    /// Shows `session`'s chat: the page switches to it and gets its state at once.
    func begin(_ session: Session) {
        self.session = session
        sessionListener?(session.event)
        follow()
    }

    /// The panel closed: later calls are refused and the state stream stops following.
    func end() {
        session = nil
        following?.cancel()
        following = nil
    }

    /// Sends the state again (the theme or the appearance changed, which Observation does not see).
    func refresh() { follow() }

    /// Stores `color` (nil: Default or Automatic) for `role` of the open chat.
    func pick(_ role: Role, _ color: HomeColor?) {
        guard let session else { return }
        var colors = store.colors(for: session.conversation)
        colors[keyPath: role.key] = color
        store.set(colors, for: session.conversation)
    }

    /// The colours the open chat draws with for `chosen`, in the panel's theme scope.
    func preview(_ chosen: HomeBubbleColors) -> HomeChatColorsPreview {
        let resolve = { [design] in HomeChatColorsPreview.resolveInScope(chosen, design: design) }
        return themeView()?.performWithTheme(resolve) ?? resolve()
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        let known = ["set", "reset", "done", "customColor"].map { Self.prefix + $0 }
        guard known.contains(op) else { throw PageError.unknownOp(op) }
        guard let session, params["session"]?.stringValue == session.id else { throw PageError.cancelled }
        switch op {
        case Self.prefix + "set":
            guard let role = params["role"]?.stringValue.flatMap(Role.init(rawValue:)) else { throw PageError.invalidParams("set: role") }
            switch params["color"] {
            case nil, .null?:
                pick(role, nil)
            case let value?:
                guard let color = value.stringValue.flatMap(HomeColor.init(hex:)) else { throw PageError.invalidParams("set: color is #RRGGBB or null") }
                pick(role, color)
            }
        case Self.prefix + "reset":
            store.set(HomeBubbleColors(), for: session.conversation)
        case Self.prefix + "customColor":
            guard let role = params["role"]?.stringValue.flatMap(Role.init(rawValue:)) else {
                throw PageError.invalidParams("customColor: role")
            }
            let colors = store.colors(for: session.conversation)
            onCustomColor?(role, colors[keyPath: role.key] ?? role.shown(in: preview(colors)))
        default:
            onDone?()
        }
        return .null
    }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        switch stream {
        case Self.sessionStream:
            sessionListener = onEvent
            if let session { onEvent(session.event) }
            return PageSubscription { [weak self] in self?.sessionListener = nil }
        case Self.stateStream:
            stateListener = onEvent
            follow()
            return PageSubscription { [weak self] in
                self?.stateListener = nil
                self?.following?.cancel()
            }
        default:
            throw PageError.unknownOp(stream)
        }
    }

    /// Sends the open chat's state now, then again whenever the store or the design settings it
    /// read change (equal states are not sent again). Stops when the panel closes or the page
    /// unsubscribes.
    private func follow() {
        following?.cancel()
        following = nil
        guard let session, let listener = stateListener else { return }
        let (now, later) = ObservationStream.current { [weak self] in self?.state(of: session) ?? .null }
        listener(now)
        // task-owner: one loop per open chat; end(), the next begin or refresh, or the page's unsubscribe cancels it
        following = Task { [weak self] in
            for await event in later {
                guard let self, !Task.isCancelled, self.session == session else { return }
                self.stateListener?(event)
            }
        }
    }

    /// The `state` event: the chat's own colours and the colours it draws with, as `#RRGGBB`.
    func state(of session: Session) -> JSONValue {
        let colors = store.colors(for: session.conversation)
        let shown = preview(colors)
        var roles: [String: JSONValue] = [:]
        for role in Role.allCases { roles[role.rawValue] = colors[keyPath: role.key].map { .string($0.hex) } ?? .null }
        func pair(_ pair: HomeChatColorsPreview.Pair) -> JSONValue { .object(["fill": .string(pair.fill.hex), "text": .string(pair.text.hex)]) }
        return .object([
            "session": .string(session.id),
            "colors": .object(roles),
            "preview": .object(["background": .string(shown.background.hex), "sent": pair(shown.sent), "received": pair(shown.received)]),
        ])
    }
}

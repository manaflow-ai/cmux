public import CmuxNextSettings
public import Foundation

/// The live preview card of computer use (B6): a small view, at the top right of an agent chat, of
/// the app window the chat's agent drives. The App owns the card (which session, its newest frame,
/// running or done); the page draws it as it comes (`computerUsePreview` event,
/// computerUsePreview.ts) and sends a click back as `chat.computerUsePreview {action}`: `open` shows
/// the session in Agent Activity, `close` hides the card for that session.
public nonisolated struct AgentPaneComputerUsePreview: Hashable, Sendable {
    /// The Computer Use session the card shows (`cua_<profile>_<ulid>`).
    public var session: String
    /// The app's name, as the helper reports it.
    public var app: String
    /// The session ended: the card keeps its last frame, dimmed, with the app's icon and a check.
    public var done: Bool
    /// The newest frame as a `data:image/...;base64,` URL; nil before the first one loads.
    public var frame: String?
    /// The app's icon as a `data:image/png;base64,` URL; nil while unknown.
    public var icon: String?
    /// Where the agent clicked last in the frame's window; the page draws its cursor there.
    public var pointer: Pointer?
    /// The agent's cursor and the person's pointer over the frame's window, as metadata the page
    /// draws (`telepointers`); `pointer` stays for pages that read only it.
    public var telepointers: Telepointers?

    public init(session: String, app: String, done: Bool, frame: String? = nil, icon: String? = nil,
                pointer: Pointer? = nil, telepointers: Telepointers? = nil) {
        self.session = session
        self.app = app
        self.done = done
        self.frame = frame
        self.icon = icon
        self.pointer = pointer
        self.telepointers = telepointers
    }

    /// A pointer over the frame's window: a fraction of it (0...1 from the top left), whether it is
    /// inside the window, and when it last moved (the page gets its age, `ageMs`).
    public struct Telepointer: Hashable, Sendable {
        public var x: Double
        public var y: Double
        public var visible: Bool
        public var movedAt: Date?
        /// Still long enough to dim: in the value, so the change reaches the page once.
        public var idle: Bool

        public init(x: Double, y: Double, visible: Bool, movedAt: Date? = nil, idle: Bool = false) {
            self.x = x
            self.y = y
            self.visible = visible
            self.movedAt = movedAt
            self.idle = idle
        }

        func json(at now: Date) -> JSONValue {
            var value: [String: JSONValue] = ["x": .number(x), "y": .number(y), "visible": .bool(visible)]
            if let movedAt { value["ageMs"] = .number(max(0, (now.timeIntervalSince(movedAt) * 1000).rounded())) }
            if idle { value["idle"] = .bool(true) }
            return .object(value)
        }
    }

    /// The agent's and the person's telepointers, each when known.
    public struct Telepointers: Hashable, Sendable {
        public var agent: Telepointer?
        public var person: Telepointer?

        public init(agent: Telepointer? = nil, person: Telepointer? = nil) {
            self.agent = agent
            self.person = person
        }
    }

    /// A point in the frame, as a fraction of it (0...1 from the top left), and the click it came
    /// from (a new one plays the click again).
    public struct Pointer: Hashable, Sendable {
        public var x: Double
        public var y: Double
        public var click: UInt64
        /// The window's width in points, when known: the page draws the cursor at the window's scale.
        public var windowWidth: Double?

        public init(x: Double, y: Double, click: UInt64, windowWidth: Double? = nil) {
            self.x = x
            self.y = y
            self.click = click
            self.windowWidth = windowWidth
        }
    }

    /// What a click on the card asks for.
    public enum Action: String, Sendable {
        /// Open Agent Activity on the card's session.
        case open
        /// Hide the card for its session.
        case close
    }

    var json: JSONValue { json(at: Date()) }

    /// The page's value, its telepointers aged at `now`.
    func json(at now: Date) -> JSONValue {
        var object: [String: JSONValue] = ["session": .string(session), "app": .string(app), "done": .bool(done)]
        if let frame { object["frame"] = .string(frame) }
        if let icon { object["icon"] = .string(icon) }
        if let pointer {
            var value: [String: JSONValue] = ["x": .number(pointer.x), "y": .number(pointer.y), "click": .number(Double(pointer.click))]
            if let width = pointer.windowWidth { value["windowWidth"] = .number(width) }
            object["pointer"] = .object(value)
        }
        if let telepointers, telepointers.agent != nil || telepointers.person != nil {
            var value: [String: JSONValue] = [:]
            if let agent = telepointers.agent { value["agent"] = agent.json(at: now) }
            if let person = telepointers.person { value["person"] = person.json(at: now) }
            object["telepointers"] = .object(value)
        }
        return .object(object)
    }

    /// `chat.computerUsePreview {action}`: the action, nil when the params break the contract.
    static func action(_ params: [String: Any]?) -> Action? {
        guard let params, Set(params.keys) == ["action"], let raw = params["action"] as? String else { return nil }
        return Action(rawValue: raw)
    }
}

extension AgentPageEvent {
    /// The chat's live preview card (`computerUsePreview`); null hides it.
    public static func computerUsePreview(_ preview: AgentPaneComputerUsePreview?) -> AgentPageEvent {
        AgentPageEvent(kind: "computerUsePreview", value: preview?.json ?? .null)
    }
}

extension AgentPaneComputerUsePreview {
    /// Shows `preview` (nil: none) on `view`'s page, a change only; the model keeps it for a page that
    /// loads later, and a click on it goes to `respond` with the card's session. Not an AgentPaneView
    /// extension: that type is at its size limit.
    @MainActor public static func show(_ preview: AgentPaneComputerUsePreview?, on view: AgentPaneView,
                                       respond: @escaping @MainActor (_ session: String, _ action: Action) -> Void) {
        view.model.onComputerUsePreview = respond
        guard preview != view.model.computerUsePreview else { return }
        view.model.computerUsePreview = preview
        replay(to: view)
    }

    /// Gives `view`'s page the card its model keeps (a page that just loaded).
    @MainActor static func replay(to view: AgentPaneView) {
        let event = AgentPageEvent.computerUsePreview(view.model.computerUsePreview)
        view.deliver([event], scripts: ["window.cmuxAcpmuxComputerUsePreview?.(\(event.value.compactText));"])
    }

    /// The reply to the page's click: the App's answer (``AgentPaneModel/onComputerUsePreview``) for
    /// the card the page shows. Open needs a real gesture in the pane (page script cannot make one).
    @MainActor static func respond(_ action: Action, in model: AgentPaneModel) -> [String: Any] {
        guard let shown = model.computerUsePreview, let onComputerUsePreview = model.onComputerUsePreview else {
            return AgentPaneModel.unsupported("chat.computerUsePreview")
        }
        if action == .open, !model.transport.gestures.consume() { return AgentPaneModel.transportFailure(.gestureRequired) }
        onComputerUsePreview(shown.session, action)
        return AgentPaneReply.success()
    }
}

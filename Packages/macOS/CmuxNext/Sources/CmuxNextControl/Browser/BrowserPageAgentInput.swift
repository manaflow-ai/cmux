public import CmuxNextSettings
/// One `browser.page.*` input an agent sent through the `cmux browser` CLI
/// (click, fill, type, press, hover, scroll, select, check, drag, upload), for the agent
/// cursor: where it landed and what it typed. The service hands it to the
/// engine (``BrowserPageEngine/announce(_:tabID:)``) after the page script
/// ran; these commands run page scripts, not driver input, so no browser
/// host event reports them.
public struct BrowserPageAgentInput: Sendable, Equatable {
    /// What the input did.
    public enum Kind: String, Sendable, Equatable {
        case click, hover, focus, type, key, scroll, select, check, drag
    }

    /// What the input did.
    public var kind: Kind
    /// The element in viewport CSS px, when the script measured one.
    public var rect: Rect?
    /// Where a drag dropped (the target element), in viewport CSS px.
    public var toRect: Rect?
    /// Typed text (`type`), the new value (`fill`, `select`), or nil.
    public var text: String?
    /// The pressed key's DOM value (`key`).
    public var key: String?
    /// The text replaces the field's value (`fill`, `select`).
    public var replace: Bool
    /// The element hides what is typed (a password field).
    public var secret: Bool
    /// The agent's name (`params.agent`, `cmux browser … --agent NAME`):
    /// its own cursor and name tag; nil draws as the unnamed CLI agent.
    public var agent: String?
    /// The terminal or chat the agent runs in (the request's `caller`): the
    /// tag names it and a click on the tag shows it; nil when unknown.
    public var origin: BrowserPageAgentOrigin?

    /// An element rect in viewport CSS px.
    public struct Rect: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        /// - Parameters: The rect's origin and size in CSS px.
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// - Parameters:
    ///   - kind: What the input did.
    ///   - rect: The element, when measured.
    ///   - toRect: A drag's drop target, when measured.
    ///   - text: The typed or set text.
    ///   - key: The pressed key.
    ///   - replace: Whether the text replaces the value.
    ///   - secret: Whether the element hides its text.
    ///   - agent: The agent's name.
    ///   - origin: Where the agent runs.
    public init(kind: Kind, rect: Rect? = nil, toRect: Rect? = nil, text: String? = nil, key: String? = nil,
                replace: Bool = false, secret: Bool = false, agent: String? = nil, origin: BrowserPageAgentOrigin? = nil) {
        self.kind = kind
        self.origin = origin
        self.rect = rect
        self.toRect = toRect
        self.agent = agent
        self.text = text
        self.key = key
        self.replace = replace
        self.secret = secret
    }

    /// The input a page script's answer describes: its `at` object
    /// (`BrowserPageScripts.measure`) gives the rect and whether the element
    /// hides its text.
    static func from(kind: Kind, answer: JSONValue, text: String? = nil, key: String? = nil, replace: Bool = false) -> BrowserPageAgentInput {
        let at = answer["at"]
        // An answer that does not say is treated as hiding its text.
        let secret = at?["secret"]?.boolValue ?? true
        return BrowserPageAgentInput(kind: kind, rect: rect(at), toRect: rect(answer["to"]), text: text, key: key,
                                     replace: replace, secret: secret)
    }

    /// This input as sent by agent `name` (nil keeps it unnamed) from `origin`.
    func by(_ name: String?, from origin: BrowserPageAgentOrigin? = nil) -> BrowserPageAgentInput {
        var copy = self
        copy.agent = name
        copy.origin = origin
        return copy
    }

    /// A measured `{x, y, w, h}` with finite, non-negative size; else nil.
    static func rect(_ at: JSONValue?) -> Rect? {
        guard let x = at?["x"]?.doubleValue, let y = at?["y"]?.doubleValue,
              let width = at?["w"]?.doubleValue, let height = at?["h"]?.doubleValue,
              [x, y, width, height].allSatisfy(\.isFinite), width >= 0, height >= 0 else { return nil }
        return Rect(x: x, y: y, width: width, height: height)
    }
}

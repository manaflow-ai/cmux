public import AppKit
public import CmuxNextSettings
import Foundation

extension PageDescriptor {
    /// The docked Home's Messages view in React (webviews/src/pages/home-messages): the conversation
    /// list and the slot the transcript, sheets and cards plug into. Like the Channels page it is a
    /// client of this instance's daemon over its loopback WebSocket (the same credential host verb,
    /// `cmux.host.credential.load`), with the Channels page's routes (Chief profile and engine, the
    /// docked view switch, the composers' edits); `cmux.home.messages.*` adds only what the app knows
    /// (``HomeMessagesPageRoute``).
    public static let homeMessages = PageDescriptor(
        id: "cmux.home-messages", resource: "home-messages",
        namespaces: ["cmux.host.credential.", "cmux.chief.profile.", "cmux.chief.backend.", "cmux.host.home.", HomeMessagesPageRoute.prefix],
        nativeOps: [PageNativeOp.edit], commands: PageNativeOp.commands.union([PageSelectionMenu.quoteCommand]),
        csp: PageCSP(connect: ["ws://127.0.0.1:*"], media: ["http://127.0.0.1:*"]), acceptsFirstMouse: true)
}

/// `cmux.home.messages.*`: what the Messages page asks of the app.
/// - `menu {kind: "row", conversation}`: a conversation row's catalog items; `{kind: "compose"}`: the
///   compose button's. Each item is `{id, title, action, arguments?, separatorBefore?, checked?}`.
/// - `perform {action, arguments}`: runs one of those actions, on the person's click only.
/// - the `chrome` stream: `{windowControls: {x, y, width, height} | null, unreadColor?}`, the window's
///   traffic lights over the page's top-left (page points) and the unread dot's colour; sent on
///   subscribe and on every change.
/// The app supplies the menus, the runs and the colour (CmuxNextApp's factory); this route owns the
/// wire shape and the gesture check.
@MainActor
public final class HomeMessagesPageRoute: PageProvider {
    public nonisolated static let prefix = "cmux.home.messages."

    /// One menu item on the wire.
    public struct Item: Sendable, Hashable {
        public var id: String
        public var title: String
        public var action: String
        public var arguments: [String: String]
        public var separatorBefore: Bool
        public var checked: Bool?

        public init(id: String, title: String, action: String, arguments: [String: String] = [:], separatorBefore: Bool = false,
                    checked: Bool? = nil) {
            (self.id, self.title, self.action, self.arguments, self.separatorBefore, self.checked) =
                (id, title, action, arguments, separatorBefore, checked)
        }

        var json: JSONValue {
            var fields: [String: JSONValue] = ["id": .string(id), "title": .string(title), "action": .string(action)]
            if !arguments.isEmpty { fields["arguments"] = .object(arguments.mapValues(JSONValue.string)) }
            if separatorBefore { fields["separatorBefore"] = .bool(true) }
            if let checked { fields["checked"] = .bool(checked) }
            return .object(fields)
        }
    }

    /// A row's items (a conversation id), or the compose button's (nil).
    private let menu: @MainActor (String?) -> [Item]
    /// Runs an action with its (text) arguments; false when it is not one the menus offer.
    private let perform: @MainActor (String, [String: String]) -> Bool
    private let unreadColor: @MainActor () -> NSColor?
    /// The refusal of a `perform` with no click behind it.
    private let personOnlyMessage: String
    private var windowControls: CGRect?
    private var listeners: [UUID: @MainActor (JSONValue) -> Void] = [:]

    public init(menu: @escaping @MainActor (String?) -> [Item], perform: @escaping @MainActor (String, [String: String]) -> Bool,
                unreadColor: @escaping @MainActor () -> NSColor?, personOnlyMessage: String) {
        self.menu = menu
        self.personOnlyMessage = personOnlyMessage
        self.perform = perform
        self.unreadColor = unreadColor
    }

    /// The traffic lights over the page, in its points from its top-left (nil: none over it).
    public func setWindowControls(_ rect: CGRect?) {
        guard rect != windowControls else { return }
        windowControls = rect
        publishChrome()
    }

    /// Sends the chrome again (the unread colour changed).
    public func publishChrome() {
        let value = chrome
        for listener in listeners.values { listener(value) }
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        let fields = params.objectValue ?? [:]
        switch op {
        case Self.prefix + "menu":
            switch fields["kind"]?.stringValue {
            case "row":
                guard let id = fields["conversation"]?.stringValue, !id.isEmpty, id.count <= 256 else {
                    throw PageError.invalidParams("conversation must be a conversation id")
                }
                return .object(["items": .array(menu(id).map(\.json))])
            case "compose":
                return .object(["items": .array(menu(nil).map(\.json))])
            default:
                throw PageError.invalidParams("kind must be row or compose")
            }
        case Self.prefix + "perform":
            guard context.userGesture else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: personOnlyMessage)
            }
            guard let action = fields["action"]?.stringValue,
                  perform(action, (fields["arguments"]?.objectValue ?? [:]).compactMapValues(\.stringValue)) else {
                throw PageError.invalidParams("not an action this page offers")
            }
            return .null
        default:
            throw PageError.unknownOp(op)
        }
    }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                          onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.prefix + "chrome" else { throw PageError.unknownOp(stream) }
        let key = UUID()
        listeners[key] = onEvent
        onEvent(chrome)
        return PageSubscription { [weak self] in
            self?.listeners[key] = nil
        }
    }

    private var chrome: JSONValue {
        var fields: [String: JSONValue] = ["windowControls": .null]
        if let rect = windowControls {
            fields["windowControls"] = .object(["x": .number(rect.minX), "y": .number(rect.minY),
                                                "width": .number(rect.width), "height": .number(rect.height)])
        }
        if let rgb = unreadColor()?.usingColorSpace(.sRGB) {
            let byte = { (value: CGFloat) in Int((max(0, min(1, value)) * 255).rounded()) }
            fields["unreadColor"] = .string(String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent),
                                                   byte(rgb.blueComponent)))
        }
        return .object(fields)
    }
}

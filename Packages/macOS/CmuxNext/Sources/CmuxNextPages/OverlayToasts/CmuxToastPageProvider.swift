public import CmuxNextDesign
public import CmuxNextSettings
public import Foundation

/// The toast stack's ops on the overlay page (`cmux-page://cmux.overlay/`, route `/toasts`): one per
/// page view, which ``CmuxToastWebHost`` claims for a window while it shows toasts there.
///
/// - stream `cmux.overlay.toasts.state` (native to page): the window's toasts, oldest first, and the
///   lowest bottom edge the stack may take (`floor`, CSS px from the page's bottom), on every change.
/// - `cmux.overlay.toasts.action {serial}`: the toast's action button (Details shows or hides its details).
/// - `cmux.overlay.toasts.close {serial}`: its close button.
/// - `cmux.overlay.toasts.hover {serial, hovered}`: the pointer came onto or left it.
/// - `cmux.overlay.toasts.layout {rects, fading}`: where the toasts rest now, and where fading ones still
///   draw (CSS px, `{serial, x, y, w, h}` from the page's top left). Native takes clicks only there and
///   keeps the chat clear of them.
@MainActor
public final class CmuxToastPageProvider: PageProvider {
    public static let stateStream = "cmux.overlay.toasts.state"

    /// One toast's rect the page reported, in CSS px from the page's top left.
    public nonisolated struct Rect: Equatable, Sendable {
        public var serial: Int
        public var x: Double, y: Double, w: Double, h: Double
    }

    /// What the page sends back; the host acts on it.
    public enum Report: Equatable, Sendable {
        case action(serial: Int)
        case close(serial: Int)
        case hover(serial: Int, hovered: Bool)
        case layout(rects: [Rect], fading: [Rect])
    }

    /// Where the page's reports go: set by the host when it claims the page for a window, cleared
    /// when it gives the page back (a report from a released page goes nowhere).
    public var onReport: (@MainActor (Report) -> Void)?
    /// The last state sent, so a new subscription (the page loaded again) starts from it.
    public private(set) var state: JSONValue = ["toasts": .array([]), "floor": 0]
    private var listeners: [Int: @MainActor (JSONValue) -> Void] = [:]
    private var nextListener = 1

    public init() {}

    /// Sends `state` to the page when it changed.
    public func publish(_ state: JSONValue) {
        guard state != self.state else { return }
        self.state = state
        for listener in listeners.values { listener(state) }
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        let report: Report
        switch op {
        case "cmux.overlay.toasts.action":
            report = .action(serial: try Self.serial(params))
        case "cmux.overlay.toasts.close":
            report = .close(serial: try Self.serial(params))
        case "cmux.overlay.toasts.hover":
            report = .hover(serial: try Self.serial(params), hovered: params["hovered"]?.boolValue ?? false)
        case "cmux.overlay.toasts.layout":
            report = .layout(rects: Self.rects(params["rects"]), fading: Self.rects(params["fading"]))
        default:
            throw PageError.unknownOp(op)
        }
        onReport?(report)
        return .null
    }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                          onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.stateStream else { throw PageError.unknownOp(stream) }
        let id = nextListener
        nextListener += 1
        listeners[id] = onEvent
        // The page draws what shows now at once (the router holds it until the reply).
        onEvent(state)
        return PageSubscription { [weak self] in self?.listeners[id] = nil }
    }

    public func pageDidClose() {
        listeners.removeAll()
    }

    private static func serial(_ params: JSONValue) throws -> Int {
        guard let value = params["serial"]?.doubleValue, value.rounded() == value, abs(value) < 1e15 else {
            throw PageError(code: "cmux.overlay.toasts.bad_serial", message: "serial must be an integer", retryable: false)
        }
        return Int(value)
    }

    /// At most a few rects (the stack shows three toasts, a few more fade); anything else is dropped.
    private static func rects(_ value: JSONValue?) -> [Rect] {
        guard case .array(let items)? = value else { return [] }
        return items.prefix(16).compactMap { item in
            guard let serial = item["serial"]?.doubleValue, let x = item["x"]?.doubleValue, let y = item["y"]?.doubleValue,
                  let w = item["w"]?.doubleValue, let h = item["h"]?.doubleValue,
                  [x, y, w, h].allSatisfy(\.isFinite), w >= 0, h >= 0, abs(serial) < 1e15 else { return nil }
            return Rect(serial: Int(serial), x: x, y: y, w: w, h: h)
        }
    }
}

extension CmuxToastPageProvider {
    /// The stream's state for `toasts` (oldest first) with the stack's lowest bottom edge `floor`
    /// (CSS px from the page's bottom).
    public static func state(_ toasts: [CmuxToastShown], floor: Double) -> JSONValue {
        .object(["toasts": .array(toasts.map(json)), "floor": .number((floor * 100).rounded() / 100)])
    }

    static func json(_ shown: CmuxToastShown) -> JSONValue {
        let toast = shown.toast
        var object: [String: JSONValue] = [
            "serial": .number(Double(shown.serial)), "id": .string(toast.id), "message": .string(toast.message),
            // Every toast has its close button.
            "closable": .bool(true),
            "showsDetails": .bool(shown.showsDetails), "showsUndoKey": .bool(shown.showsUndoKey),
        ]
        if let detail = toast.detail { object["detail"] = .string(detail) }
        if let action = toast.action {
            object["action"] = ["title": .string(action.title), "isUndo": .bool(action.isUndo),
                                "revealsDetails": .bool(action.revealsDetails)]
        }
        return .object(object)
    }
}

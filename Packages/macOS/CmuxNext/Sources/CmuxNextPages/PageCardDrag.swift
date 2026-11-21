public import CmuxNextSettings
public import Foundation

/// A page card the person drags between the places its native host keeps for it (the sidebar's
/// Updated card, Leo 2026-11-07: "what if you could, like, drag around the updated to nightly, and
/// you can drag that up to the top if you wanted to?"). The page runs the drag (webviews
/// `ui/anchors.ts`); the host only moves its view.
///
/// - `<prefix>drag {x, y, anchor?}`: how far the page holds the card from where it rests, CSS px;
///   with `anchor`, the card was let go and settles at that anchor (`top`, `bottom`).
/// - `<prefix>place`: a stream of where the card rests, `{anchor, above, below, zoom}`: its anchor, the
///   room, CSS px, from its edges to the farthest place it may rest above and below, and the zoom, so
///   the page reads the pointer's screen deltas (points) in CSS px.
///
/// The host speaks points; the page is zoomed (the interface scale), so one CSS px is ``zoom`` points.
@MainActor
public final class PageCardDrag: PageProvider {
    public let prefix: String
    /// Points per CSS px: the page's zoom, read at each report.
    public var zoom: @MainActor () -> CGFloat = { 1 }
    /// The page holds the card `offset` points from its rest; a non-nil anchor is its drop.
    public var onDrag: (@MainActor (_ offset: CGPoint, _ anchor: String?) -> Void)?
    private var place: JSONValue = .null
    private var listeners: [UUID: @MainActor (JSONValue) -> Void] = [:]

    public init(prefix: String) {
        self.prefix = prefix
    }

    /// Where the card rests now, in points: each subscription hears it at once, then each change.
    public func setPlace(anchor: String, above: CGFloat, below: CGFloat) {
        let scale = max(zoom(), 0.01)
        let next: JSONValue = .object(["anchor": .string(anchor), "above": .number(Double((above / scale).rounded())),
                                       "below": .number(Double((below / scale).rounded())), "zoom": .number(Double(scale))])
        guard next != place else { return }
        place = next
        for listener in listeners.values { listener(next) }
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op == prefix + "drag" else { throw PageError.unknownOp(op) }
        guard let x = params["x"]?.doubleValue, let y = params["y"]?.doubleValue, x.isFinite, y.isFinite else {
            throw PageError.invalidParams("x and y are required")
        }
        let scale = zoom()
        onDrag?(CGPoint(x: x * scale, y: y * scale), params["anchor"]?.stringValue)
        return .null
    }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                          onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == prefix + "place" else { throw PageError.unknownOp(stream) }
        let id = UUID()
        listeners[id] = onEvent
        if place != .null { onEvent(place) }
        return PageSubscription { [weak self] in self?.listeners[id] = nil }
    }
}

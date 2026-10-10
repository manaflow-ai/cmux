import Foundation
import WebKit

/// `input.drag { targetId, path: [{x, y}], button, modifiers }`. A native
/// HTML5 drag in a WKWebView would start an AppKit dragging session: the
/// system drag pasteboard and the person's pointer. So, as the CDP driver
/// keeps the drag's data inside the call (cdp/drag.rs), a drag that starts
/// on a draggable element is played in the main frame's host world:
/// `dragstart` on the source with a `DataTransfer`, `dragenter`,
/// `dragleave` and `dragover` along the path, `drop` where the last
/// `dragover` was accepted, then `dragend` (untrusted events). A drag on
/// anything else is the plain mouse: press, moves, release.
extension WebKitDriver {
    private static let startsHTMLDrag = """
    const el = document.elementFromPoint(x, y);
    const source = el && el.closest('[draggable="true"], a[href], img');
    return !!source && source.draggable !== false;
    """

    private static let playHTMLDrag = """
    const source = document.elementFromPoint(points[0].x, points[0].y).closest('[draggable="true"], a[href], img');
    const data = new DataTransfer();
    const fire = (type, el, p) => el.dispatchEvent(new DragEvent(type, {
      bubbles: true, cancelable: true, composed: true, clientX: p.x, clientY: p.y, dataTransfer: data,
      shiftKey: mods.includes("Shift"), altKey: mods.includes("Alt"), ctrlKey: mods.includes("Control"), metaKey: mods.includes("Meta"),
    }));
    if (!fire("dragstart", source, points[0])) return "cancelled";
    let over = null;
    let accepted = false;
    const last = points[points.length - 1];
    for (const p of points.slice(1)) {
      const el = document.elementFromPoint(p.x, p.y);
      if (el !== over) {
        if (over) fire("dragleave", over, p);
        if (el) fire("dragenter", el, p);
        over = el;
      }
      accepted = el ? !fire("dragover", el, p) : false;
    }
    if (over && accepted) fire("drop", over, last);
    fire("dragend", source, last);
    return accepted ? "dropped" : "ended";
    """

    func inputDrag(_ params: DriverParams) async throws(DriverError) -> DriverJSON {
        let (tab, _) = try target(params)
        var points: [[String: Double]] = []
        for point in try params.array("path") {
            guard case .object(let fields) = point, case .number(let x)? = fields["x"], case .number(let y)? = fields["y"] else {
                throw DriverError(.invalid, "path: expected [{ x, y }, ...] with one point or more")
            }
            points.append(["x": x, "y": y])
        }
        guard let start = points.first else { throw DriverError(.invalid, "path: expected [{ x, y }, ...] with one point or more") }
        let modifiers = try params.strings("modifiers")
        let html = try await run(Self.startsHTMLDrag, ["x": start["x"] ?? 0, "y": start["y"] ?? 0], nil, AgentWorld.hostWorld, tab)
        if html == .bool(true) {
            _ = try await run(Self.playHTMLDrag, ["points": points, "mods": modifiers], nil, AgentWorld.hostWorld, tab)
            return .null
        }
        let button = try params.optionalString("button") ?? "left"
        func mouse(_ type: String, _ point: [String: Double]) async throws(DriverError) {
            _ = try await inputMouse(DriverParams(method: "input.mouse", json: .object([
                "targetId": .string(tab.id.rawValue), "type": .string(type), "button": .string(button),
                "x": .number(point["x"] ?? 0), "y": .number(point["y"] ?? 0),
                "modifiers": .array(modifiers.map(DriverJSON.string)),
            ])))
        }
        try await mouse("move", start)
        try await mouse("down", start)
        for point in points.dropFirst() { try await mouse("move", point) }
        try await mouse("up", points[points.count - 1])
        return .null
    }
}

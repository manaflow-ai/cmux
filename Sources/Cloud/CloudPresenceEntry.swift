import CoreFoundation
import Foundation

/// Where one teammate points inside a cmux-tui surface. Mirrors the daemon's
/// `PresenceAnchor` (`cmux-tui/spec/presence.md`).
enum CloudPresenceAnchor: Equatable, Sendable {
    /// A terminal cell. `row` and `col` are inside the publisher's viewport;
    /// `scrollOffset` is how many rows that viewport sits above the live
    /// bottom, so a viewer at another offset can shift the row.
    case cell(row: Int, col: Int, scrollOffset: UInt64)
    /// A browser or display point in CSS/document pixels.
    case point(x: Double, y: Double)

    var json: [String: Any] {
        switch self {
        case let .cell(row, col, scrollOffset):
            return ["kind": "cell", "row": row, "col": col, "scroll_offset": scrollOffset]
        case let .point(x, y):
            return ["kind": "point", "x": x, "y": y]
        }
    }

    init?(json: Any?) {
        guard let object = json as? [String: Any], let kind = object["kind"] as? String else { return nil }
        switch kind {
        case "cell":
            guard let row = CloudPresenceEntry.int(object["row"]),
                  let col = CloudPresenceEntry.int(object["col"]) else { return nil }
            let offset: UInt64
            if object["scroll_offset"] == nil {
                offset = 0
            } else {
                guard let parsed = CloudPresenceEntry.uint64(object["scroll_offset"]),
                      parsed <= UInt64(Int64.max) else { return nil }
                offset = parsed
            }
            self = .cell(row: row, col: col, scrollOffset: offset)
        case "point":
            guard let x = (object["x"] as? NSNumber)?.doubleValue,
                  let y = (object["y"] as? NSNumber)?.doubleValue else { return nil }
            self = .point(x: x, y: y)
        default:
            return nil
        }
    }

    /// The row a viewer whose viewport sits `viewerScrollOffset` rows above
    /// the live bottom must draw this cell on. Nil when the row is off screen.
    func viewerRow(viewerScrollOffset: UInt64, rows: Int) -> Int? {
        guard let shifted = shiftedRow(viewerScrollOffset: viewerScrollOffset) else { return nil }
        guard shifted >= 0, shifted < Int64(rows) else { return nil }
        return Int(shifted)
    }

    func shiftedRow(viewerScrollOffset: UInt64) -> Int64? {
        guard case let .cell(row, _, publisherOffset) = self,
              let row = Int64(exactly: row),
              let viewerOffset = Int64(exactly: viewerScrollOffset),
              let publisherOffset = Int64(exactly: publisherOffset) else { return nil }
        let (withViewer, addOverflow) = row.addingReportingOverflow(viewerOffset)
        let (shifted, subtractOverflow) = withViewer.subtractingReportingOverflow(publisherOffset)
        guard !addOverflow, !subtractOverflow else { return nil }
        return shifted
    }
}

enum CloudPresenceHighlightMode: String, Sendable {
    /// Fades on the viewer after a couple of seconds.
    case laser
    /// Stays until the publisher clears it or disconnects.
    case pin
}

struct CloudPresenceHighlight: Equatable, Sendable {
    let start: CloudPresenceAnchor
    let end: CloudPresenceAnchor
    let mode: CloudPresenceHighlightMode

    var json: [String: Any] {
        ["start": start.json, "end": end.json, "mode": mode.rawValue]
    }

    init(start: CloudPresenceAnchor, end: CloudPresenceAnchor, mode: CloudPresenceHighlightMode) {
        self.start = start
        self.end = end
        self.mode = mode
    }

    init?(json: Any?) {
        guard let object = json as? [String: Any],
              let start = CloudPresenceAnchor(json: object["start"]),
              let end = CloudPresenceAnchor(json: object["end"]),
              let mode = (object["mode"] as? String).flatMap(CloudPresenceHighlightMode.init(rawValue:)) else {
            return nil
        }
        self.init(start: start, end: end, mode: mode)
    }
}

/// One `presence-changed` payload: the latest pointer and highlight of one
/// daemon connection. `surface == nil` means that connection cleared its
/// presence, disconnected, or its surface exited.
struct CloudPresenceEntry: Equatable, Sendable {
    let client: UInt64
    let name: String?
    let kind: String?
    /// Palette slot in `0..<8`, stable for the connection.
    let color: Int
    let surface: UInt64?
    let pointer: CloudPresenceAnchor?
    let highlight: CloudPresenceHighlight?
    let updatedAtMs: UInt64
    let generation: UInt64

    var isCleared: Bool { surface == nil }

    init?(json object: [String: Any]) {
        guard let client = (object["client"] as? NSNumber)?.uint64Value,
              let generation = (object["generation"] as? NSNumber)?.uint64Value else { return nil }
        self.client = client
        name = object["name"] as? String
        kind = object["kind"] as? String
        color = Int((object["color"] as? NSNumber)?.intValue ?? 0) & 7
        surface = (object["surface"] as? NSNumber).flatMap { $0.uint64Value > 0 ? $0.uint64Value : nil }
        pointer = CloudPresenceAnchor(json: object["pointer"])
        highlight = CloudPresenceHighlight(json: object["highlight"])
        updatedAtMs = (object["updated_at_ms"] as? NSNumber)?.uint64Value ?? 0
        self.generation = generation
    }

    static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let signed = number.int64Value
        guard signed >= 0, signed <= Int64(Int32.max) else { return nil }
        return Int(signed)
    }

    static func uint64(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        switch String(cString: number.objCType) {
        case "c", "s", "i", "l", "q":
            let signed = number.int64Value
            return signed >= 0 ? UInt64(signed) : nil
        case "C", "S", "I", "L", "Q":
            return number.uint64Value
        default:
            return nil
        }
    }
}

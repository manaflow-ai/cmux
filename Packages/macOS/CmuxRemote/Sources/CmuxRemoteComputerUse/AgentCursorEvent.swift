// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation

/// One `cursor` callback (cursor.rs `CursorEvent`, JSON tagged by `kind`).
struct AgentCursorEvent: Equatable, Sendable {
    enum Kind: String, Sendable {
        case move, click, typing, look, hide
    }

    var kind: Kind
    var session: String
    /// The agent's name, shown next to its cursor.
    var label: String
    /// Global desktop points, top-left origin.
    var at: CGPoint?
    /// Typing: the text (shortened for the caption).
    var text: String

    init(kind: Kind, session: String, label: String = "", at: CGPoint? = nil, text: String = "") {
        self.kind = kind
        self.session = session
        self.label = label
        self.at = at
        self.text = text
    }

    init?(json: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let kind = (object["kind"] as? String).flatMap(Kind.init(rawValue:)),
              let session = object["session"] as? String else { return nil }
        var point: CGPoint?
        if let at = object["at"] as? [String: Any], let x = (at["x"] as? NSNumber)?.doubleValue,
           let y = (at["y"] as? NSNumber)?.doubleValue, x.isFinite, y.isFinite {
            point = CGPoint(x: x, y: y)
        }
        self.init(kind: kind, session: session, label: object["label"] as? String ?? "", at: point,
                  text: object["text"] as? String ?? "")
    }

    /// The typing caption: one line, at most `limit` characters (no secret shows in full).
    static func caption(_ text: String, limit: Int = 24) -> String {
        let line = String(text.map { $0.isNewline || $0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? " " : $0 })
        guard line.count > limit else { return line }
        return String(line.prefix(limit - 1)) + "\u{2026}"
    }
}

/// Desktop points (top-left origin, the primary display's top-left at 0,0) to AppKit screen
/// points (bottom-left origin) and back.
struct AgentCursorGeometry: Equatable, Sendable {
    /// The primary display's height in points.
    var primaryHeight: CGFloat

    func appKit(_ desktop: CGPoint) -> CGPoint {
        CGPoint(x: desktop.x, y: primaryHeight - desktop.y)
    }

    /// The screen frame (AppKit) that holds `point` (AppKit), else the nearest one.
    static func screen(containing point: CGPoint, in frames: [CGRect]) -> CGRect? {
        if let hit = frames.first(where: { $0.contains(point) }) { return hit }
        return frames.min { distance($0, point) < distance($1, point) }
    }

    private static func distance(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}

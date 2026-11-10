// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation

/// One `cursor` callback (cursor.rs `CursorEvent`, JSON tagged by `kind`).
struct AgentCursorEvent: Equatable, Sendable {
    enum Kind: String, Sendable {
        case move, click, typing, keys, scroll, drag, look, hide
    }

    var kind: Kind
    var session: String
    /// The agent's name, shown next to its cursor.
    var label: String
    /// Global desktop points, top-left origin. A drag's end.
    var at: CGPoint?
    /// Typing: the text (shortened for the caption). Keys: the combo ("cmd+s").
    var text: String
    /// Click: the button ("left", "right", "middle") and the count (2: double click).
    var button: String = "left"
    var count: Int = 1
    /// Scroll: lines (dy > 0 down).
    var scroll: CGVector = .zero
    /// Drag: where it started (global desktop points).
    var from: CGPoint?
    /// Look: the window looked at (global desktop points, top-left origin).
    var rect: CGRect?

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
        let at = Self.point(object["at"]) ?? Self.point(object["to"])
        let text = object["text"] as? String ?? object["keys"] as? String ?? ""
        self.init(kind: kind, session: session, label: object["label"] as? String ?? "", at: at, text: text)
        button = object["button"] as? String ?? "left"
        count = min(max((object["count"] as? NSNumber)?.intValue ?? 1, 1), 3)
        let dx = (object["dx"] as? NSNumber)?.doubleValue ?? 0
        let dy = (object["dy"] as? NSNumber)?.doubleValue ?? 0
        scroll = CGVector(dx: dx.isFinite ? dx : 0, dy: dy.isFinite ? dy : 0)
        from = Self.point(object["from"])
        if let r = object["rect"] as? [String: Any],
           let x = (r["x"] as? NSNumber)?.doubleValue, let y = (r["y"] as? NSNumber)?.doubleValue,
           let w = (r["width"] as? NSNumber)?.doubleValue, let h = (r["height"] as? NSNumber)?.doubleValue,
           [x, y, w, h].allSatisfy(\.isFinite), w > 0, h > 0 {
            rect = CGRect(x: x, y: y, width: w, height: h)
        }
    }

    private static func point(_ value: Any?) -> CGPoint? {
        guard let at = value as? [String: Any], let x = (at["x"] as? NSNumber)?.doubleValue,
              let y = (at["y"] as? NSNumber)?.doubleValue, x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// The typing caption: one line, at most `limit` characters (no secret shows in full).
    static func caption(_ text: String, limit: Int = 24) -> String {
        let line = String(text.map { $0.isNewline || $0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? " " : $0 })
        guard line.count > limit else { return line }
        return String(line.prefix(limit - 1)) + "\u{2026}"
    }

    /// A key combo ("cmd+shift+s", "Return") as the key caps a Mac shows: ["⌘", "⇧", "S"].
    static func keyCaps(_ combo: String) -> [String] {
        let names: [String: String] = [
            "cmd": "\u{2318}", "command": "\u{2318}", "meta": "\u{2318}", "super": "\u{2318}",
            "shift": "\u{21E7}", "alt": "\u{2325}", "option": "\u{2325}", "opt": "\u{2325}",
            "ctrl": "\u{2303}", "control": "\u{2303}", "fn": "fn",
            "return": "\u{21A9}", "enter": "\u{2324}", "tab": "\u{21E5}", "escape": "esc", "esc": "esc",
            "space": "space", "backspace": "\u{232B}", "delete": "\u{232B}", "forwarddelete": "\u{2326}",
            "up": "\u{2191}", "down": "\u{2193}", "left": "\u{2190}", "right": "\u{2192}",
            "arrowup": "\u{2191}", "arrowdown": "\u{2193}", "arrowleft": "\u{2190}", "arrowright": "\u{2192}",
            "home": "\u{2196}", "end": "\u{2198}", "pageup": "\u{21DE}", "pagedown": "\u{21DF}",
        ]
        let parts = combo.split(separator: "+", omittingEmptySubsequences: true).map(String.init)
        return parts.prefix(6).map { part in
            let key = part.trimmingCharacters(in: .whitespaces)
            if let name = names[key.lowercased()] { return name }
            return key.count == 1 ? key.uppercased() : String(key.prefix(6))
        }
    }

    /// What the cursor's action chip says for a click.
    static func clickTitle(button: String, count: Int) -> String {
        switch (button, count) {
        case ("right", _): ComputerUseText.t("computerUse.cursor.rightClick", "Right-click")
        case ("middle", _): ComputerUseText.t("computerUse.cursor.middleClick", "Middle-click")
        case (_, 2): ComputerUseText.t("computerUse.cursor.doubleClick", "Double-click")
        case (_, 3): ComputerUseText.t("computerUse.cursor.tripleClick", "Triple-click")
        default: ComputerUseText.t("computerUse.cursor.click", "Click")
        }
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

    /// A desktop rect (top-left origin) in AppKit screen points.
    func appKit(_ desktop: CGRect) -> CGRect {
        CGRect(x: desktop.minX, y: primaryHeight - desktop.maxY, width: desktop.width, height: desktop.height)
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

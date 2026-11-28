import Foundation

/// One agent input (`automation.input` v1, manaflow-ai/cmux
/// schemas/automation-input/event.schema.json). Drivers publish it after
/// their policy and frame checks, right before dispatch. Coordinates are
/// never screen points: `viewport` is unzoomed CSS px of the top-level
/// document viewport, `window` is window-local points of a desktop window.
public struct AutomationInputEvent: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case move, click, drag, type, key, scroll
        case doubleClick = "double_click"
        case rightClick = "right_click"
    }

    public enum Space: String, Sendable {
        case viewport, window
    }

    public struct Point: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public struct Rect: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var w: Double
        public var h: Double
        public init(x: Double, y: Double, w: Double, h: Double) {
            self.x = x
            self.y = y
            self.w = w
            self.h = h
        }
    }

    public var sessionID: String
    public var targetID: String
    public var seq: UInt64
    public var kind: Kind
    public var space: Space
    public var point: Point?
    public var rect: Rect?
    public var to: Point?
    /// Page zoom at emit time (viewport space only); `nil` means 1.
    public var zoom: Double?
    public var tMs: Double

    public init(
        sessionID: String, targetID: String, seq: UInt64, kind: Kind, space: Space,
        point: Point? = nil, rect: Rect? = nil, to: Point? = nil, zoom: Double? = nil, tMs: Double
    ) {
        self.sessionID = sessionID
        self.targetID = targetID
        self.seq = seq
        self.kind = kind
        self.space = space
        self.point = point
        self.rect = rect
        self.to = to
        self.zoom = zoom
        self.tMs = tMs
    }
}

public enum AutomationInputEventError: Error, Equatable {
    case notAnObject
    case unknownField(String)
    case missingField(String)
    case invalidField(String)
    case unsupportedVersion
    case pointRequired
    case toRequired
    case wrongSpace
    case zoomNotAllowed
}

extension AutomationInputEvent {
    /// Decodes and validates one event; rejects anything the schema rejects.
    public static func decode(_ data: Data) throws -> AutomationInputEvent {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AutomationInputEventError.notAnObject
        }
        let allowed: Set<String> = ["v", "session_id", "target_id", "seq", "kind", "space", "point", "rect", "to", "zoom", "t_ms"]
        if let unknown = object.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw AutomationInputEventError.unknownField(unknown)
        }
        guard let version = object["v"] as? NSNumber else { throw AutomationInputEventError.missingField("v") }
        guard version.intValue == 1, version.doubleValue == 1 else { throw AutomationInputEventError.unsupportedVersion }
        let sessionID = try nonEmptyString(object, "session_id")
        let targetID = try nonEmptyString(object, "target_id")
        guard let seqNumber = object["seq"] as? NSNumber else { throw AutomationInputEventError.missingField("seq") }
        guard seqNumber.doubleValue >= 0, seqNumber.doubleValue == seqNumber.doubleValue.rounded(.towardZero) else {
            throw AutomationInputEventError.invalidField("seq")
        }
        guard let kindRaw = object["kind"] as? String else { throw AutomationInputEventError.missingField("kind") }
        guard let kind = Kind(rawValue: kindRaw) else { throw AutomationInputEventError.invalidField("kind") }
        guard let spaceRaw = object["space"] as? String else { throw AutomationInputEventError.missingField("space") }
        guard let space = Space(rawValue: spaceRaw) else { throw AutomationInputEventError.invalidField("space") }
        guard let tMs = (object["t_ms"] as? NSNumber)?.doubleValue else { throw AutomationInputEventError.missingField("t_ms") }
        guard tMs >= 0 else { throw AutomationInputEventError.invalidField("t_ms") }
        let point = try object["point"].map { try decodePoint($0, "point") }
        let to = try object["to"].map { try decodePoint($0, "to") }
        let rect = try object["rect"].map { try decodeRect($0) }
        var zoom: Double?
        if let raw = object["zoom"] {
            guard let value = (raw as? NSNumber)?.doubleValue else { throw AutomationInputEventError.invalidField("zoom") }
            guard value > 0 else { throw AutomationInputEventError.invalidField("zoom") }
            zoom = value
        }

        let needsPoint: Set<Kind> = [.move, .click, .doubleClick, .rightClick, .drag, .scroll]
        if needsPoint.contains(kind), point == nil { throw AutomationInputEventError.pointRequired }
        if kind == .drag || kind == .scroll, to == nil { throw AutomationInputEventError.toRequired }
        let desktop = targetID.hasPrefix("cua:")
        if desktop != (space == .window) { throw AutomationInputEventError.wrongSpace }
        if space == .window, zoom != nil { throw AutomationInputEventError.zoomNotAllowed }

        return AutomationInputEvent(
            sessionID: sessionID, targetID: targetID, seq: seqNumber.uint64Value, kind: kind, space: space,
            point: point, rect: rect, to: to, zoom: zoom, tMs: tMs
        )
    }

    private static func nonEmptyString(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String else { throw AutomationInputEventError.missingField(key) }
        guard !value.isEmpty else { throw AutomationInputEventError.invalidField(key) }
        return value
    }

    private static func number(_ object: [String: Any], _ key: String, in field: String) throws -> Double {
        guard let value = object[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else {
            throw AutomationInputEventError.invalidField(field)
        }
        return value.doubleValue
    }

    private static func decodePoint(_ raw: Any, _ field: String) throws -> Point {
        guard let object = raw as? [String: Any], Set(object.keys) == ["x", "y"] else {
            throw AutomationInputEventError.invalidField(field)
        }
        return Point(x: try number(object, "x", in: field), y: try number(object, "y", in: field))
    }

    private static func decodeRect(_ raw: Any) throws -> Rect {
        guard let object = raw as? [String: Any], Set(object.keys) == ["x", "y", "w", "h"] else {
            throw AutomationInputEventError.invalidField("rect")
        }
        let rect = Rect(
            x: try number(object, "x", in: "rect"), y: try number(object, "y", in: "rect"),
            w: try number(object, "w", in: "rect"), h: try number(object, "h", in: "rect")
        )
        guard rect.w >= 0, rect.h >= 0 else { throw AutomationInputEventError.invalidField("rect") }
        return rect
    }
}

public import CmuxMobileWire
import Foundation

/// One `cmux.rb/1` input event (tag `e`). On the wire it rides as the bytes
/// of an rd `service` input event, so it is applied once and in order.
/// Coordinates are the page's CSS pixels.
public enum RbInputEvent: Hashable, Sendable {
    case key(RbKeyEvent)
    case pointer(kind: RbPointerKind, x: Double, y: Double, button: UInt8, buttons: UInt8, clickCount: UInt8,
                 modifiers: RbModifiers, pointerType: String)
    case wheel(x: Double, y: Double, dx: Double, dy: Double, precise: Bool, phase: RbPhase, momentumPhase: RbPhase,
               modifiers: RbModifiers)
    case pinch(phase: RbPhase, scale: Double, x: Double, y: Double)
    case imeSetComposition(text: String, underlines: [RbUnderline], selectionStart: UInt32, selectionEnd: UInt32,
                           replacement: RbTextRange?)
    case imeCommit(text: String, replacement: RbTextRange?)
    case imeFinish(keepSelection: Bool)
    case imeCancel

    /// The surface every phone event targets (the main page).
    public static let mainSurface: UInt32 = 0

    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = ["surface": .int(Int64(Self.mainSurface))]
        switch self {
        case .key(let key):
            object["e"] = .string("key")
            object["down"] = .bool(key.down)
            object["code"] = .string(key.code)
            object["key"] = .string(key.key)
            object["text"] = .string(key.text)
            object["unmodified_text"] = .string(key.unmodifiedText)
            object["modifiers"] = .int(Int64(key.modifiers.rawValue))
            object["repeat"] = .bool(key.isRepeat)
            object["location"] = .int(Int64(key.location))
            object["edit_commands"] = .array(key.editCommands.map { .object(["name": .string($0.name), "value": .string($0.value)]) })
        case .pointer(let kind, let x, let y, let button, let buttons, let clicks, let modifiers, let type):
            object["e"] = .string("pointer")
            object["kind"] = .string(kind.rawValue)
            object["x"] = .double(x)
            object["y"] = .double(y)
            object["button"] = .int(Int64(button))
            object["buttons"] = .int(Int64(buttons))
            object["click_count"] = .int(Int64(clicks))
            object["modifiers"] = .int(Int64(modifiers.rawValue))
            object["pointer_type"] = .string(type)
        case .wheel(let x, let y, let dx, let dy, let precise, let phase, let momentum, let modifiers):
            object["e"] = .string("wheel")
            object["x"] = .double(x)
            object["y"] = .double(y)
            object["dx"] = .double(dx)
            object["dy"] = .double(dy)
            object["precise"] = .bool(precise)
            object["phase"] = .string(phase.rawValue)
            object["momentum_phase"] = .string(momentum.rawValue)
            object["modifiers"] = .int(Int64(modifiers.rawValue))
        case .pinch(let phase, let scale, let x, let y):
            object["e"] = .string("pinch")
            object["phase"] = .string(phase.rawValue)
            object["scale"] = .double(scale)
            object["x"] = .double(x)
            object["y"] = .double(y)
        case .imeSetComposition(let text, let underlines, let start, let end, let replacement):
            object["e"] = .string("ime_set_composition")
            object["text"] = .string(text)
            object["underlines"] = .array(underlines.map {
                .object(["start": .int(Int64($0.start)), "end": .int(Int64($0.end)), "thick": .bool($0.thick)])
            })
            object["selection_start"] = .int(Int64(start))
            object["selection_end"] = .int(Int64(end))
            object["replacement"] = Self.json(replacement)
        case .imeCommit(let text, let replacement):
            object["e"] = .string("ime_commit")
            object["text"] = .string(text)
            object["replacement"] = Self.json(replacement)
        case .imeFinish(let keep):
            object["e"] = .string("ime_finish")
            object["keep_selection"] = .bool(keep)
        case .imeCancel:
            object["e"] = .string("ime_cancel")
        }
        return .object(object)
    }

    public init(json: JSONValue) throws(RdWireError) {
        let r = try RbJSONReader(json)
        switch try r.string("e") {
        case "key":
            self = .key(RbKeyEvent(down: try r.bool("down"), code: try r.string("code"), key: try r.string("key"),
                                   text: try r.string("text"), unmodifiedText: try r.string("unmodified_text"),
                                   modifiers: RbModifiers(rawValue: try r.uint32("modifiers")), isRepeat: try r.bool("repeat"),
                                   location: UInt8(clamping: try r.int("location")), editCommands: try Self.editCommands(r)))
        case "pointer":
            guard let kind = RbPointerKind(rawValue: try r.string("kind")) else { throw RdWireError("pointer kind") }
            self = .pointer(kind: kind, x: try r.double("x"), y: try r.double("y"), button: UInt8(clamping: try r.int("button")),
                            buttons: UInt8(clamping: try r.int("buttons")), clickCount: UInt8(clamping: try r.int("click_count")),
                            modifiers: RbModifiers(rawValue: try r.uint32("modifiers")), pointerType: try r.string("pointer_type"))
        case "wheel":
            self = .wheel(x: try r.double("x"), y: try r.double("y"), dx: try r.double("dx"), dy: try r.double("dy"),
                          precise: try r.bool("precise"), phase: try Self.phase(r, "phase"),
                          momentumPhase: try Self.phase(r, "momentum_phase"),
                          modifiers: RbModifiers(rawValue: try r.uint32("modifiers")))
        case "pinch":
            self = .pinch(phase: try Self.phase(r, "phase"), scale: try r.double("scale"), x: try r.double("x"), y: try r.double("y"))
        case "ime_set_composition":
            var underlines: [RbUnderline] = []
            for value in try r.array("underlines") {
                let u = try RbJSONReader(value)
                underlines.append(RbUnderline(start: try u.uint32("start"), end: try u.uint32("end"), thick: try u.bool("thick")))
            }
            self = .imeSetComposition(text: try r.string("text"), underlines: underlines,
                                      selectionStart: try r.uint32("selection_start"), selectionEnd: try r.uint32("selection_end"),
                                      replacement: try Self.range(r))
        case "ime_commit": self = .imeCommit(text: try r.string("text"), replacement: try Self.range(r))
        case "ime_finish": self = .imeFinish(keepSelection: try r.bool("keep_selection"))
        case "ime_cancel": self = .imeCancel
        case let other: throw RdWireError("input event \(other)")
        }
    }

    /// The rd input event that carries this event (`must_deliver`).
    public func rdEvent() throws(RdWireError) -> RdInputEvent {
        guard let data = try? jsonValue.canonicalData() else { throw RdWireError("rb input does not encode") }
        guard data.count <= RdInputEvent.maxServiceBytes else { throw RdWireError("rb input above one packet") }
        return .service(mustDeliver: true, bytes: data)
    }

    /// Decodes the rb event inside an rd `service` input event.
    public init(rdEvent: RdInputEvent) throws(RdWireError) {
        guard case .service(_, let bytes) = rdEvent else { throw RdWireError("not a service input event") }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: bytes) else { throw RdWireError("service bytes are not JSON") }
        try self.init(json: value)
    }

    private static func editCommands(_ r: RbJSONReader) throws(RdWireError) -> [RbEditCommand] {
        guard !r.isNull("edit_commands") else { return [] }
        var out: [RbEditCommand] = []
        for value in try r.array("edit_commands") {
            let c = try RbJSONReader(value)
            out.append(RbEditCommand(name: try c.string("name"), value: try c.string("value")))
        }
        return out
    }

    private static func phase(_ r: RbJSONReader, _ key: String) throws(RdWireError) -> RbPhase {
        guard let phase = RbPhase(rawValue: try r.string(key)) else { throw RdWireError("\(key)") }
        return phase
    }

    private static func range(_ r: RbJSONReader) throws(RdWireError) -> RbTextRange? {
        if r.isNull("replacement") { return nil }
        let values = try r.array("replacement")
        guard values.count == 2, case .int(let lower) = values[0], case .int(let upper) = values[1],
              let start = UInt32(exactly: lower), let end = UInt32(exactly: upper), start <= end else {
            throw RdWireError("replacement")
        }
        return RbTextRange(start: start, end: end)
    }

    private static func json(_ range: RbTextRange?) -> JSONValue {
        guard let range else { return .null }
        return .array([.int(Int64(range.start)), .int(Int64(range.end))])
    }
}

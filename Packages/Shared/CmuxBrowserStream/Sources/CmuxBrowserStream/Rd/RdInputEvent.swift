public import Foundation

/// One viewer input event (cmux-rd-proto `InputEvent`). Browser channels use
/// `.service` with a `cmux.rb/1` input event as JSON bytes.
public enum RdInputEvent: Hashable, Sendable {
    /// Largest UTF-8 text of `.text`.
    public static let maxTextBytes = 256
    /// Largest payload of `.service`.
    public static let maxServiceBytes = 1127

    case key(usage: UInt32, down: Bool)
    case pointer(x: Int32, y: Int32)
    case button(button: UInt8, down: Bool)
    case scroll(dx: Int32, dy: Int32, precise: Bool)
    case text(String)
    case service(mustDeliver: Bool, bytes: Data)

    func encode(into out: inout Data) throws(RdWireError) {
        switch self {
        case .key(let usage, let down):
            out.append(1)
            out.appendRd(usage)
            out.append(down ? 1 : 0)
        case .pointer(let x, let y):
            out.append(2)
            out.appendRd(x)
            out.appendRd(y)
        case .button(let button, let down):
            out.append(3)
            out.append(button)
            out.append(down ? 1 : 0)
        case .scroll(let dx, let dy, let precise):
            out.append(4)
            out.appendRd(dx)
            out.appendRd(dy)
            out.append(precise ? 1 : 0)
        case .text(let text):
            let bytes = Data(Self.truncate(text).utf8)
            out.append(5)
            out.appendRd(UInt16(bytes.count))
            out.append(bytes)
        case .service(let mustDeliver, let bytes):
            guard bytes.count <= Self.maxServiceBytes else { throw RdWireError("service event above \(Self.maxServiceBytes) bytes") }
            out.append(0x80)
            out.append(mustDeliver ? 1 : 0)
            out.appendRd(UInt16(bytes.count))
            out.append(bytes)
        }
    }

    static func decode(_ reader: inout RdByteReader) throws(RdWireError) -> RdInputEvent {
        switch try reader.u8() {
        case 1: return .key(usage: try reader.u32(), down: try reader.bool())
        case 2: return .pointer(x: try reader.i32(), y: try reader.i32())
        case 3: return .button(button: try reader.u8(), down: try reader.bool())
        case 4: return .scroll(dx: try reader.i32(), dy: try reader.i32(), precise: try reader.bool())
        case 5:
            let length = Int(try reader.u16())
            guard length <= maxTextBytes else { throw RdWireError("text length") }
            guard let text = String(data: try reader.take(length), encoding: .utf8) else { throw RdWireError("utf-8 text") }
            return .text(text)
        case 0x80:
            let flags = try reader.u8()
            guard flags & ~1 == 0 else { throw RdWireError("service event flags") }
            let length = Int(try reader.u16())
            guard length <= maxServiceBytes else { throw RdWireError("service event length") }
            return .service(mustDeliver: flags & 1 != 0, bytes: try reader.take(length))
        case let tag:
            throw RdWireError("input tag \(tag)")
        }
    }

    /// The longest prefix of `text` that fits `maxTextBytes` on a character boundary.
    private static func truncate(_ text: String) -> String {
        guard text.utf8.count > maxTextBytes else { return text }
        var out = ""
        for character in text {
            guard out.utf8.count + String(character).utf8.count <= maxTextBytes else { break }
            out.append(character)
        }
        return out
    }
}

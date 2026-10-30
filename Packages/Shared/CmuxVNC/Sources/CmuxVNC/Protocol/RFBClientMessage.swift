import Foundation

/// Client-to-server messages (RFC 6143 section 7.5) as exact wire bytes.
struct RFBClientMessage {
    var bytes: [UInt8] = []

    private mutating func u16(_ value: UInt16) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xFF))
    }

    private mutating func u32(_ value: UInt32) {
        bytes.append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    static func setPixelFormat(_ format: RFBPixelFormat) -> [UInt8] {
        [0, 0, 0, 0] + format.encoded
    }

    static func setEncodings(_ encodings: [RFBEncoding]) -> [UInt8] {
        var message = RFBClientMessage(bytes: [2, 0])
        message.u16(UInt16(encodings.count))
        for encoding in encodings { message.u32(UInt32(bitPattern: encoding.rawValue)) }
        return message.bytes
    }

    static func framebufferUpdateRequest(incremental: Bool, x: Int, y: Int, width: Int, height: Int) -> [UInt8] {
        var message = RFBClientMessage(bytes: [3, incremental ? 1 : 0])
        message.u16(UInt16(clamping: x))
        message.u16(UInt16(clamping: y))
        message.u16(UInt16(clamping: width))
        message.u16(UInt16(clamping: height))
        return message.bytes
    }

    static func keyEvent(keysym: UInt32, down: Bool) -> [UInt8] {
        var message = RFBClientMessage(bytes: [4, down ? 1 : 0, 0, 0])
        message.u32(keysym)
        return message.bytes
    }

    static func pointerEvent(buttons: UInt8, x: Int, y: Int) -> [UInt8] {
        var message = RFBClientMessage(bytes: [5, buttons])
        message.u16(UInt16(clamping: max(0, x)))
        message.u16(UInt16(clamping: max(0, y)))
        return message.bytes
    }

    /// Latin-1 only (RFC 6143): other characters become `?`.
    static func clientCutText(_ text: String) -> [UInt8] {
        let latin1 = text.unicodeScalars.map { $0.value > 0xFF ? UInt8(ascii: "?") : UInt8($0.value) }
        var message = RFBClientMessage(bytes: [6, 0, 0, 0])
        message.u32(UInt32(latin1.count))
        message.bytes.append(contentsOf: latin1)
        return message.bytes
    }
}

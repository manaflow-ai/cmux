import Foundation

/// Encoders for the client-to-server messages cmux sends (RFC 6143 §7.5).
///
/// Every encoder is a pure function returning the exact wire bytes, which makes
/// the protocol layer trivially unit-testable without a live socket.
public enum RFBClientMessage {
    /// Server-to-client encoding identifiers we advertise, best first. The
    /// server picks the first it supports for each rectangle.
    public enum Encoding: Int32, Sendable {
        case raw = 0
        case copyRect = 1
        case rre = 2
        case hextile = 5
        // Pseudo-encodings (advertised so the server may use them).
        case desktopSize = -223
        case cursor = -239
    }

    private static func u16(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    private static func u32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    /// `SetPixelFormat` (message type 0): pin the server to our render format.
    public static func setPixelFormat(_ format: RFBPixelFormat) -> [UInt8] {
        var bytes: [UInt8] = [0, 0, 0, 0] // type + 3 padding
        bytes.append(contentsOf: format.encoded())
        return bytes
    }

    /// `SetEncodings` (message type 2).
    public static func setEncodings(_ encodings: [Encoding]) -> [UInt8] {
        var bytes: [UInt8] = [2, 0] // type + 1 padding
        bytes.append(contentsOf: u16(UInt16(encodings.count)))
        for encoding in encodings {
            bytes.append(contentsOf: u32(UInt32(bitPattern: encoding.rawValue)))
        }
        return bytes
    }

    /// `FramebufferUpdateRequest` (message type 3). `incremental == false`
    /// asks for a full refresh of the region.
    public static func framebufferUpdateRequest(
        incremental: Bool,
        x: UInt16,
        y: UInt16,
        width: UInt16,
        height: UInt16
    ) -> [UInt8] {
        var bytes: [UInt8] = [3, incremental ? 1 : 0]
        bytes.append(contentsOf: u16(x))
        bytes.append(contentsOf: u16(y))
        bytes.append(contentsOf: u16(width))
        bytes.append(contentsOf: u16(height))
        return bytes
    }

    /// `KeyEvent` (message type 4). `key` is an X11 keysym.
    public static func keyEvent(keysym: UInt32, down: Bool) -> [UInt8] {
        var bytes: [UInt8] = [4, down ? 1 : 0, 0, 0]
        bytes.append(contentsOf: u32(keysym))
        return bytes
    }

    /// `PointerEvent` (message type 5). `buttonMask` bit 0 = left, 1 = middle,
    /// 2 = right, 3 = wheel-up, 4 = wheel-down.
    public static func pointerEvent(buttonMask: UInt8, x: UInt16, y: UInt16) -> [UInt8] {
        var bytes: [UInt8] = [5, buttonMask]
        bytes.append(contentsOf: u16(x))
        bytes.append(contentsOf: u16(y))
        return bytes
    }

    /// `ClientCutText` (message type 6): clipboard text from client to server.
    public static func clientCutText(_ text: String) -> [UInt8] {
        let latin1 = text.unicodeScalars.map { UInt8($0.value > 0xFF ? 0x3F : $0.value) }
        var bytes: [UInt8] = [6, 0, 0, 0]
        bytes.append(contentsOf: u32(UInt32(latin1.count)))
        bytes.append(contentsOf: latin1)
        return bytes
    }
}

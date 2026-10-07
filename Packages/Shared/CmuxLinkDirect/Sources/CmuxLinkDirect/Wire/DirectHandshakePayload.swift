import Foundation

/// The payloads inside the Noise handshake messages.
/// Message 1: `u8 version | u16 LE length | hostID utf8`. Message 2: `u8 version`.
struct DirectHandshakePayload: Sendable, Hashable {
    static let version: UInt8 = 1
    /// The Noise prologue: both ends must agree on it or the handshake fails.
    static let prologue = Data("cmux.direct/1".utf8)

    /// The host the dialer meant to reach (nil in message 2).
    var hostID: String?

    func encoded() -> Data {
        var data = Data([Self.version])
        if let hostID {
            let bytes = Data(hostID.utf8)
            let length = UInt16(clamping: bytes.count)
            withUnsafeBytes(of: length.littleEndian) { data.append(contentsOf: $0) }
            data.append(bytes.prefix(Int(length)))
        }
        return data
    }

    init(hostID: String?) {
        self.hostID = hostID
    }

    init(decoding data: Data, expectsHostID: Bool) throws {
        let data = Data(data)
        guard let version = data.first else { throw DirectWireError.truncated }
        guard version == Self.version else { throw DirectWireError.unsupportedVersion(version) }
        guard expectsHostID else {
            hostID = nil
            return
        }
        guard data.count >= 3 else { throw DirectWireError.truncated }
        let length = Int(data[1]) | Int(data[2]) << 8
        guard data.count == 3 + length, let hostID = String(data: data.subdata(in: 3..<(3 + length)), encoding: .utf8) else {
            throw DirectWireError.truncated
        }
        self.hostID = hostID
    }
}

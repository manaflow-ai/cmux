import Foundation

public enum VNCIPCMessageType: UInt8, Sendable {
    case control = 1
    case frame = 2
}

public struct VNCConnectRequest: Codable, Equatable, Sendable {
    public var sessionName: String
    public var host: String
    public var port: Int
    public var username: String
    public var password: String

    public init(sessionName: String, host: String, port: Int, username: String, password: String) {
        self.sessionName = sessionName
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }
}

public struct VNCControlMessage: Codable, Equatable, Sendable {
    public var kind: String
    public var sessionName: String?
    public var host: String?
    public var port: Int?
    public var username: String?
    public var password: String?
    public var state: String?
    public var message: String?
    public var visible: Bool?
    public var text: String?
    public var x: Int?
    public var y: Int?
    public var button: Int?
    public var isDown: Bool?
    public var width: Int?
    public var height: Int?

    public init(
        kind: String,
        sessionName: String? = nil,
        host: String? = nil,
        port: Int? = nil,
        username: String? = nil,
        password: String? = nil,
        state: String? = nil,
        message: String? = nil,
        visible: Bool? = nil,
        text: String? = nil,
        x: Int? = nil,
        y: Int? = nil,
        button: Int? = nil,
        isDown: Bool? = nil,
        width: Int? = nil,
        height: Int? = nil
    ) {
        self.kind = kind
        self.sessionName = sessionName
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.state = state
        self.message = message
        self.visible = visible
        self.text = text
        self.x = x
        self.y = y
        self.button = button
        self.isDown = isDown
        self.width = width
        self.height = height
    }

    public static func connect(_ request: VNCConnectRequest) -> VNCControlMessage {
        VNCControlMessage(
            kind: "connect",
            sessionName: request.sessionName,
            host: request.host,
            port: request.port,
            username: request.username,
            password: request.password
        )
    }
}

public enum VNCIPCMessage: Equatable, Sendable {
    case control(VNCControlMessage)
    case frame(VNCFrameHeader, Data)
}

public enum VNCIPCError: Error, Equatable, Sendable {
    case payloadTooLarge
    case unknownMessageType(UInt8)
    case invalidFrameHeader
}

public enum VNCIPCCodec {
    public static let maxMessageLength = 256 * 1024 * 1024
    private static let frameHeaderLength = 41

    public static func encodeControl(_ message: VNCControlMessage) throws -> Data {
        let json = try JSONEncoder().encode(message)
        var payload = Data([VNCIPCMessageType.control.rawValue])
        payload.append(json)
        return try framed(payload)
    }

    public static func encodeFrame(header: VNCFrameHeader, payload framePayload: Data) throws -> Data {
        if VNCFrameValidator.validate(header: header, payloadByteCount: framePayload.count) != nil {
            throw VNCIPCError.invalidFrameHeader
        }
        guard let x = UInt32(exactly: header.x),
              let y = UInt32(exactly: header.y),
              let width = UInt32(exactly: header.width),
              let height = UInt32(exactly: header.height),
              let framebufferWidth = UInt32(exactly: header.framebufferWidth),
              let framebufferHeight = UInt32(exactly: header.framebufferHeight),
              let stride = UInt32(exactly: header.stride) else {
            throw VNCIPCError.invalidFrameHeader
        }
        var payload = Data([VNCIPCMessageType.frame.rawValue])
        payload.appendUInt64BE(header.sequence)
        payload.appendUInt32BE(x)
        payload.appendUInt32BE(y)
        payload.appendUInt32BE(width)
        payload.appendUInt32BE(height)
        payload.appendUInt32BE(framebufferWidth)
        payload.appendUInt32BE(framebufferHeight)
        payload.appendUInt32BE(stride)
        payload.appendUInt32BE(header.pixelFormat.rawValue)
        payload.append(framePayload)
        return try framed(payload)
    }

    public static func decodePayload(_ payload: Data) throws -> VNCIPCMessage {
        guard let typeByte = payload.first else { throw VNCIPCError.invalidFrameHeader }
        guard let type = VNCIPCMessageType(rawValue: typeByte) else {
            throw VNCIPCError.unknownMessageType(typeByte)
        }
        let body = payload.dropFirst()
        switch type {
        case .control:
            return try .control(JSONDecoder().decode(VNCControlMessage.self, from: Data(body)))
        case .frame:
            guard body.count >= frameHeaderLength - 1 else { throw VNCIPCError.invalidFrameHeader }
            var cursor = body.startIndex
            let sequence = try body.readUInt64BE(cursor: &cursor)
            let x = Int(try body.readUInt32BE(cursor: &cursor))
            let y = Int(try body.readUInt32BE(cursor: &cursor))
            let width = Int(try body.readUInt32BE(cursor: &cursor))
            let height = Int(try body.readUInt32BE(cursor: &cursor))
            let framebufferWidth = Int(try body.readUInt32BE(cursor: &cursor))
            let framebufferHeight = Int(try body.readUInt32BE(cursor: &cursor))
            let stride = Int(try body.readUInt32BE(cursor: &cursor))
            let pixelRaw = try body.readUInt32BE(cursor: &cursor)
            guard let pixelFormat = VNCFramePixelFormat(rawValue: pixelRaw) else {
                throw VNCIPCError.invalidFrameHeader
            }
            let framePayload = Data(body[cursor...])
            let header = VNCFrameHeader(
                sequence: sequence,
                x: x,
                y: y,
                width: width,
                height: height,
                framebufferWidth: framebufferWidth,
                framebufferHeight: framebufferHeight,
                stride: stride,
                pixelFormat: pixelFormat
            )
            if VNCFrameValidator.validate(header: header, payloadByteCount: framePayload.count) != nil {
                throw VNCIPCError.invalidFrameHeader
            }
            return .frame(header, framePayload)
        }
    }

    private static func framed(_ payload: Data) throws -> Data {
        guard payload.count <= maxMessageLength else {
            throw VNCIPCError.payloadTooLarge
        }
        var output = Data()
        output.appendUInt32BE(UInt32(payload.count))
        output.append(payload)
        return output
    }
}

public struct VNCIPCStreamDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) throws -> [VNCIPCMessage] {
        buffer.append(data)
        var messages: [VNCIPCMessage] = []
        while true {
            guard buffer.count >= 4 else { break }
            let length = Int(buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            if length > VNCIPCCodec.maxMessageLength {
                throw VNCIPCError.payloadTooLarge
            }
            guard buffer.count >= 4 + length else { break }
            let payload = Data(buffer[4..<(4 + length)])
            messages.append(try VNCIPCCodec.decodePayload(payload))
            buffer.removeSubrange(0..<(4 + length))
        }
        return messages
    }
}

private extension Data {
    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendUInt64BE(_ value: UInt64) {
        append(UInt8((value >> 56) & 0xff))
        append(UInt8((value >> 48) & 0xff))
        append(UInt8((value >> 40) & 0xff))
        append(UInt8((value >> 32) & 0xff))
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }
}

private extension Data.SubSequence {
    func readUInt32BE(cursor: inout Index) throws -> UInt32 {
        guard distance(from: cursor, to: endIndex) >= 4 else {
            throw VNCIPCError.invalidFrameHeader
        }
        var value: UInt32 = 0
        for _ in 0..<4 {
            value = (value << 8) | UInt32(self[cursor])
            cursor = index(after: cursor)
        }
        return value
    }

    func readUInt64BE(cursor: inout Index) throws -> UInt64 {
        guard distance(from: cursor, to: endIndex) >= 8 else {
            throw VNCIPCError.invalidFrameHeader
        }
        var value: UInt64 = 0
        for _ in 0..<8 {
            value = (value << 8) | UInt64(self[cursor])
            cursor = index(after: cursor)
        }
        return value
    }
}

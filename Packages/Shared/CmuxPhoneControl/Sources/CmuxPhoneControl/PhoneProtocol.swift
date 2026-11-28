import Foundation

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// lint:allow namespace-type — versioned wire limits are dependency-free protocol constants.
public enum PhoneProtocol {
    public static let name = "cmux.phone"
    public static let version = 1
    /// Control requests stay small; responses may carry a base64 screenshot.
    /// A future binary frame transport can lower the response-line limit
    /// without changing request or action semantics.
    public static let maxRequestLineBytes = 64 * 1024
    public static let maxResponseLineBytes = 8 * 1024 * 1024
    /// Backwards-compatible name for the largest wire line.
    public static let maxLineBytes = maxResponseLineBytes
}

public enum PhoneMessageType: String, Codable, Sendable {
    case request
    case response
    case event
    case error
}

public struct PhoneError: Codable, Equatable, Sendable, Error {
    public let code: String
    public let message: String
    public let retryable: Bool
    public let details: PhoneJSONValue?

    public init(
        code: String,
        message: String,
        retryable: Bool = false,
        details: PhoneJSONValue? = nil
    ) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.details = details
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case code
        case message
        case retryable
        case details
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let knownKeys = Set(CodingKeys.allCases.map(\.stringValue))
        let unknownKeys = try decoder.container(keyedBy: AnyCodingKey.self).allKeys.filter {
            !knownKeys.contains($0.stringValue)
        }
        if !unknownKeys.isEmpty {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath + [unknownKeys[0]],
                debugDescription: "unknown error field \(unknownKeys[0].stringValue)"
            ))
        }
        code = try container.decode(String.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        retryable = try container.decode(Bool.self, forKey: .retryable)
        details = try container.decodeIfPresent(PhoneJSONValue.self, forKey: .details)
    }
}

/// All control traffic is newline-delimited JSON. Binary frame transports can
/// be added later without changing request/response semantics.
public struct PhoneEnvelope: Codable, Equatable, Sendable {
    public let protocolName: String
    public let version: Int
    public let type: PhoneMessageType
    public let id: String?
    public let method: String?
    public let sessionID: String?
    public let sequence: UInt64?
    public let timestamp: Double?
    public let params: PhoneJSONValue?
    public let result: PhoneJSONValue?
    public let error: PhoneError?

    public init(
        type: PhoneMessageType,
        id: String? = nil,
        method: String? = nil,
        sessionID: String? = nil,
        sequence: UInt64? = nil,
        timestamp: Double? = nil,
        params: PhoneJSONValue? = nil,
        result: PhoneJSONValue? = nil,
        error: PhoneError? = nil,
        protocolName: String = PhoneProtocol.name,
        version: Int = PhoneProtocol.version
    ) {
        self.protocolName = protocolName
        self.version = version
        self.type = type
        self.id = id
        self.method = method
        self.sessionID = sessionID
        self.sequence = sequence
        self.timestamp = timestamp
        self.params = params
        self.result = result
        self.error = error
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case protocolName = "protocol"
        case version
        case type
        case id
        case method
        case sessionID = "session_id"
        case sequence = "seq"
        case timestamp = "ts"
        case params
        case result
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let knownKeys = Set(CodingKeys.allCases.map(\.stringValue))
        let unknownKeys = try decoder.container(keyedBy: AnyCodingKey.self).allKeys.filter {
            !knownKeys.contains($0.stringValue)
        }
        if let unknownKey = unknownKeys.first {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath + [unknownKey],
                debugDescription: "unknown envelope field \(unknownKey.stringValue)"
            ))
        }
        protocolName = try container.decode(String.self, forKey: .protocolName)
        version = try container.decode(Int.self, forKey: .version)
        type = try container.decode(PhoneMessageType.self, forKey: .type)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        method = try container.decodeIfPresent(String.self, forKey: .method)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        sequence = try container.decodeIfPresent(UInt64.self, forKey: .sequence)
        timestamp = try container.decodeIfPresent(Double.self, forKey: .timestamp)
        params = try container.decodeIfPresent(PhoneJSONValue.self, forKey: .params)
        result = try container.decodeIfPresent(PhoneJSONValue.self, forKey: .result)
        error = try container.decodeIfPresent(PhoneError.self, forKey: .error)
    }

    public static func request(
        id: String,
        method: String,
        sessionID: String? = nil,
        params: PhoneJSONValue? = nil
    ) -> Self {
        Self(type: .request, id: id, method: method, sessionID: sessionID, params: params)
    }

    public static func response(
        id: String,
        sessionID: String? = nil,
        result: PhoneJSONValue? = nil
    ) -> Self {
        Self(type: .response, id: id, sessionID: sessionID, result: result)
    }

    public static func failure(
        id: String?,
        sessionID: String? = nil,
        error: PhoneError
    ) -> Self {
        Self(type: .error, id: id, sessionID: sessionID, error: error)
    }

    public static func event(
        method: String,
        sessionID: String,
        sequence: UInt64? = nil,
        result: PhoneJSONValue? = nil
    ) -> Self {
        Self(
            type: .event,
            method: method,
            sessionID: sessionID,
            sequence: sequence,
            timestamp: Date().timeIntervalSince1970,
            result: result
        )
    }
}

public enum PhoneWireCodecError: Error, Equatable, Sendable {
    case lineTooLarge
    case missingNewline
    case invalidJSON
    case invalidProtocol
    case unsupportedVersion(Int)
    case invalidMessageType
}

public struct PhoneWireCodec: Sendable {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public func encode(_ envelope: PhoneEnvelope) throws -> Data {
        var data = try encoder.encode(envelope)
        let limit = envelope.type == .request
            ? PhoneProtocol.maxRequestLineBytes
            : PhoneProtocol.maxResponseLineBytes
        guard data.count + 1 <= limit else {
            throw PhoneWireCodecError.lineTooLarge
        }
        data.append(0x0A)
        return data
    }

    public func decode(
        _ data: Data,
        maxLineBytes: Int = PhoneProtocol.maxRequestLineBytes
    ) throws -> PhoneEnvelope {
        guard data.last == 0x0A else { throw PhoneWireCodecError.missingNewline }
        guard data.count <= maxLineBytes else {
            throw PhoneWireCodecError.lineTooLarge
        }
        let payload = data.dropLast()
        guard let envelope = try? decoder.decode(PhoneEnvelope.self, from: payload) else {
            throw PhoneWireCodecError.invalidJSON
        }
        guard envelope.protocolName == PhoneProtocol.name else {
            throw PhoneWireCodecError.invalidProtocol
        }
        guard envelope.version == PhoneProtocol.version else {
            throw PhoneWireCodecError.unsupportedVersion(envelope.version)
        }
        switch envelope.type {
        case .request:
            guard let id = envelope.id, !id.isEmpty,
                  let method = envelope.method, !method.isEmpty else {
                throw PhoneWireCodecError.invalidMessageType
            }
        case .response:
            guard let id = envelope.id, !id.isEmpty else {
                throw PhoneWireCodecError.invalidMessageType
            }
        case .event:
            guard let method = envelope.method, !method.isEmpty,
                  let sessionID = envelope.sessionID, !sessionID.isEmpty else {
                throw PhoneWireCodecError.invalidMessageType
            }
        case .error:
            guard envelope.error != nil else {
                throw PhoneWireCodecError.invalidMessageType
            }
        }
        return envelope
    }
}

public struct PhoneLineDecoder: Sendable {
    private var buffer = Data()
    private let codec = PhoneWireCodec()
    private let maxLineBytes: Int

    public init(maxLineBytes: Int = PhoneProtocol.maxResponseLineBytes) {
        self.maxLineBytes = maxLineBytes
    }

    public mutating func append(_ data: Data) throws -> [PhoneEnvelope] {
        buffer.append(data)
        guard buffer.count <= maxLineBytes * 2 else {
            throw PhoneWireCodecError.lineTooLarge
        }

        var envelopes: [PhoneEnvelope] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let end = buffer.index(after: newline)
            let line = Data(buffer[..<end])
            buffer.removeSubrange(..<end)
            envelopes.append(try codec.decode(line, maxLineBytes: maxLineBytes))
        }
        if buffer.count > maxLineBytes {
            throw PhoneWireCodecError.lineTooLarge
        }
        return envelopes
    }
}

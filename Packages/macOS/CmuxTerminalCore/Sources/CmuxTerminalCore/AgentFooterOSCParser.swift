public import Foundation

/// Parses pane footer metadata from an incremental OSC 699 byte stream.
///
/// The parser accepts both BEL and ST terminators and keeps partial sequences
/// across calls because PTY reads may split an escape sequence at any byte.
/// Payloads use semicolon-separated `key=value` pairs, for example:
///
/// ```text
/// ESC ] 699 ; agent=claude ; context=34% ESC \\
/// ```
public struct AgentFooterOSCParser: Sendable {
    private enum Phase: Sendable {
        case ground
        case escape
        case oscCode([UInt8])
        case otherOSC
        case otherOSCEscape
        case footerPayload([UInt8])
        case footerPayloadEscape([UInt8])
        case discardFooterPayload
        case discardFooterPayloadEscape
    }

    private static let footerCode = Array("699".utf8)
    private static let maximumCodeBytes = 3
    private static let maximumPayloadBytes = 1_024
    private var phase: Phase = .ground

    /// Creates an empty parser.
    public init() {}

    /// Consumes one borrowed PTY output chunk and returns the latest complete update.
    ///
    /// - Parameter bytes: Raw PTY output bytes.
    /// - Returns: The latest footer snapshot completed by this chunk, if any.
    public mutating func consume(_ bytes: UnsafeBufferPointer<UInt8>) -> AgentFooterState? {
        var latest: AgentFooterState?
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            if let update = consume(byte) {
                latest = update
            }
            index += 1
        }
        return latest
    }

    /// Consumes one PTY output chunk and returns the latest complete update.
    ///
    /// - Parameter data: Raw PTY output bytes.
    /// - Returns: The latest footer snapshot completed by this chunk, if any.
    public mutating func consume(_ data: Data) -> AgentFooterState? {
        data.withUnsafeBytes { rawBuffer in
            consume(rawBuffer.bindMemory(to: UInt8.self))
        }
    }

    private mutating func consume(_ byte: UInt8) -> AgentFooterState? {
        switch phase {
        case .ground:
            if byte == 0x1B {
                phase = .escape
            } else if byte == 0x9D {
                phase = .oscCode([])
            }
        case .escape:
            if byte == 0x5D {
                phase = .oscCode([])
            } else if byte == 0x1B {
                phase = .escape
            } else {
                phase = .ground
            }
        case let .oscCode(code):
            if byte == 0x07 {
                phase = .ground
                return nil
            }
            if byte == 0x9C {
                phase = .ground
                return nil
            }
            if byte == 0x1B {
                phase = .otherOSCEscape
                return nil
            }
            if byte == 0x3B {
                if code == Self.footerCode {
                    phase = .footerPayload([])
                } else {
                    phase = .otherOSC
                }
                return nil
            }
            if (byte == 0x20 || byte == 0x09), !code.isEmpty {
                return nil
            }
            guard byte >= 0x30, byte <= 0x39, code.count < Self.maximumCodeBytes else {
                phase = .otherOSC
                return nil
            }
            phase = .oscCode(code + [byte])
        case .otherOSC:
            if byte == 0x07 {
                phase = .ground
            } else if byte == 0x9C {
                phase = .ground
            } else if byte == 0x1B {
                phase = .otherOSCEscape
            }
        case .otherOSCEscape:
            if byte == 0x5C {
                phase = .ground
            } else if byte == 0x1B {
                phase = .otherOSCEscape
            } else {
                phase = .otherOSC
            }
        case let .footerPayload(payload):
            if byte == 0x07 {
                phase = .ground
                return Self.state(from: payload)
            }
            if byte == 0x9C {
                phase = .ground
                return Self.state(from: payload)
            }
            if byte == 0x1B {
                phase = .footerPayloadEscape(payload)
            } else if payload.count < Self.maximumPayloadBytes {
                phase = .footerPayload(payload + [byte])
            } else {
                phase = .discardFooterPayload
            }
        case let .footerPayloadEscape(payload):
            if byte == 0x5C {
                phase = .ground
                return Self.state(from: payload)
            }
            if byte == 0x1B {
                phase = .footerPayloadEscape(Self.append(byte, to: payload))
            } else {
                phase = .footerPayload(Self.append(byte, to: Self.append(0x1B, to: payload)))
            }
        case .discardFooterPayload:
            if byte == 0x07 {
                phase = .ground
            } else if byte == 0x9C {
                phase = .ground
            } else if byte == 0x1B {
                phase = .discardFooterPayloadEscape
            }
        case .discardFooterPayloadEscape:
            if byte == 0x5C {
                phase = .ground
            } else if byte != 0x1B {
                phase = .discardFooterPayload
            }
        }
        return nil
    }

    private static func append(_ byte: UInt8, to payload: [UInt8]) -> [UInt8] {
        guard payload.count < maximumPayloadBytes else { return payload }
        return payload + [byte]
    }

    private static func state(from payload: [UInt8]) -> AgentFooterState? {
        let text = String(decoding: payload, as: UTF8.self)
        var fields: [String: String] = [:]
        for field in text.split(separator: ";", omittingEmptySubsequences: false) {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            fields[key] = value
        }

        guard fields["agent"] != nil || fields["context"] != nil || fields["state"] != nil else {
            return nil
        }
        if fields["state"]?.lowercased() == "exited" || fields["state"]?.lowercased() == "stopped" {
            return AgentFooterState(agent: nil, contextPercent: nil)
        }
        let agent = fields["agent"]
        let context: Int?
        if let rawValue = fields["context"] {
            let value = rawValue.hasSuffix("%") ? String(rawValue.dropLast()) : rawValue
            guard let parsed = Int(value), (0...100).contains(parsed) else { return nil }
            context = parsed
        } else {
            context = nil
        }
        guard agent != nil || context != nil else { return nil }
        return AgentFooterState(agent: agent, contextPercent: context)
    }
}

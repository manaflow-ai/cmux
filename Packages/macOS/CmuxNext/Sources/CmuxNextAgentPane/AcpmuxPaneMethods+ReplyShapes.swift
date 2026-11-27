import Foundation

/// The replies the relay filters itself (ad349), of ``AcpmuxPaneMethods``: read-only requests
/// whose reply reaches the pane cut to the fields it renders.
nonisolated extension AcpmuxPaneMethods {
    /// The shape of a reply the relay filters itself, without relying on the daemon's redaction.
    public nonisolated indirect enum ReplyShape: Sendable {
        case string
        /// A JSON `true` or `false` only; a number or a string that reads as one is dropped.
        case bool
        /// A finite JSON number that is not a boolean; anything else is dropped.
        case number
        case object([String: ReplyShape])
        case list(ReplyShape)
        /// Only the scheme of the URL in the sibling field `source` (`ssh`, `ws`, `wss`), so the
        /// page learns a peer's transport without its URL (which can carry a user or a token).
        case scheme(from: String)
    }

    /// The URL schemes a `.scheme` field may report; any other scheme is dropped.
    static let reportedSchemes: Set<String> = ["ssh", "ws", "wss"]

    /// `value` cut to `shape`: nil when it does not fit (a list keeps only the items that fit).
    static func filtered(_ value: Any, to shape: ReplyShape) -> Any? {
        switch shape {
        case .string:
            return value as? String
        case .bool:
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        case .number:
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite else { return nil }
            return number
        case .scheme:
            guard let scheme = (value as? String).flatMap(Self.reportedScheme) else { return nil }
            return scheme
        case .list(let item):
            return (value as? [Any])?.compactMap { filtered($0, to: item) }
        case .object(let fields):
            guard let object = value as? [String: Any] else { return nil }
            let kept = fields.compactMap { key, field -> (String, Any)? in
                let source: String
                if case .scheme(let from) = field { source = from } else { source = key }
                return object[source].flatMap { filtered($0, to: field) }.map { (key, $0) }
            }
            // An object with none of its fields is dropped (a peer with no name renders nothing).
            return kept.isEmpty ? nil : Dictionary(uniqueKeysWithValues: kept)
        }
    }

    /// A reply to a filtered request, rebuilt with the page's id (raw JSON) and its filtered
    /// result. An error keeps only its code and message.
    static func filteredReply(_ object: [String: Any], shape: ReplyShape, pageID: String) -> String? {
        let id = (try? JSONSerialization.jsonObject(with: Data(pageID.utf8), options: [.fragmentsAllowed])) ?? NSNull()
        var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if let error = object["error"] as? [String: Any] {
            reply["error"] = ["code": Self.integerCode(error["code"]) ?? -32603,
                               "message": error["message"] as? String ?? ""]
        } else {
            reply["result"] = object["result"].flatMap { filtered($0, to: shape) } ?? [String: Any]()
        }
        guard let data = try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The integer form used by Swift's `NSNumber` bridge for a daemon error code.
    /// Integral JSON doubles and booleans are accepted; fractional and out-of-range values use
    /// JSON-RPC's internal-error fallback, matching the Rust policy crate.
    private static func integerCode(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? 1 : 0 }
        let value = number.doubleValue
        guard value.isFinite, value.rounded(.towardZero) == value,
              value >= -9_223_372_036_854_775_808.0,
              value < 9_223_372_036_854_775_808.0 else { return nil }
        return Int(value)
    }

    /// The strict RFC 3986 subset used for a reported peer transport. Foundation's URL parser
    /// accepts some malformed strings on newer macOS releases, so the host checks the grammar
    /// itself before exposing only the lower-cased scheme.
    private static func reportedScheme(_ value: String) -> String? {
        let bytes = Array(value.utf8)
        guard let colon = bytes.firstIndex(of: 0x3a), colon > 0 else { return nil }
        let scheme = Array(bytes[..<colon])
        guard scheme.first.map({ isASCIIAlpha($0) }) == true,
              scheme.dropFirst().allSatisfy({ isASCIIAlpha($0) || isASCIIDigit($0) || $0 == 0x2b || $0 == 0x2d || $0 == 0x2e }) else { return nil }

        var rest = Array(bytes[(colon + 1)...])
        let fragment = splitOnce(&rest, on: 0x23)
        guard uriCharacters(fragment, extra: [0x3a, 0x40, 0x2f, 0x3f]) else { return nil }
        let query = splitOnce(&rest, on: 0x3f)
        guard uriCharacters(query, extra: [0x3a, 0x40, 0x2f, 0x3f]) else { return nil }

        let path: [UInt8]
        if rest.starts(with: [0x2f, 0x2f]) {
            let afterAuthority = Array(rest.dropFirst(2))
            let slash = afterAuthority.firstIndex(of: 0x2f)
            let authority = Array(afterAuthority[..<(slash ?? afterAuthority.endIndex)])
            guard validAuthority(authority) else { return nil }
            path = slash.map { Array(afterAuthority[$0...]) } ?? []
        } else {
            path = rest
        }
        guard uriCharacters(path, extra: [0x3a, 0x40, 0x2f]) else { return nil }

        let lower = String(decoding: scheme, as: UTF8.self).lowercased()
        return reportedSchemes.contains(lower) ? lower : nil
    }

    /// Splits at the first delimiter, returning the suffix and removing it from `rest`.
    private static func splitOnce(_ rest: inout [UInt8], on delimiter: UInt8) -> [UInt8] {
        guard let index = rest.firstIndex(of: delimiter) else { return [] }
        let suffix = Array(rest[(index + 1)...])
        rest = Array(rest[..<index])
        return suffix
    }

    private static func validAuthority(_ authority: [UInt8]) -> Bool {
        let userInfo: [UInt8]?
        let hostPort: [UInt8]
        if let at = authority.firstIndex(of: 0x40) {
            userInfo = Array(authority[..<at])
            hostPort = Array(authority[(at + 1)...])
            guard !authority[(at + 1)...].contains(0x40),
                  userInfo!.filter({ $0 == 0x3a }).count <= 1,
                  uriCharacters(userInfo!, extra: [0x3a]) else { return false }
        } else {
            userInfo = nil
            hostPort = authority
        }
        if hostPort.first == 0x5b {
            guard let close = hostPort.firstIndex(of: 0x5d), close > 1,
                  validIPv6(Array(hostPort[(hostPort.index(after: hostPort.startIndex))..<close])) else { return false }
            let suffix = Array(hostPort[(close + 1)...])
            if suffix.isEmpty { return true }
            guard suffix.first == 0x3a else { return false }
            let port = Array(suffix.dropFirst())
            return !port.isEmpty && port.allSatisfy(isASCIIDigit)
        }
        let portIndex = hostPort.firstIndex(of: 0x3a)
        let host = Array(hostPort[..<(portIndex ?? hostPort.endIndex)])
        guard uriCharacters(host, extra: []) else { return false }
        if let portIndex {
            let port = Array(hostPort[(portIndex + 1)...])
            guard !port.isEmpty, port.allSatisfy(isASCIIDigit) else { return false }
        }
        return true
    }

    private static func validIPv6(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return false }
        var text = String(decoding: bytes, as: UTF8.self)
        if let dot = text.lastIndex(of: ".") {
            guard let colon = text[..<dot].lastIndex(of: ":"), colon < dot else { return false }
            let ipv4 = text[text.index(after: colon)...]
            let octets = ipv4.split(separator: ".", omittingEmptySubsequences: false)
            guard octets.count == 4,
                  octets.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy(Self.isASCIIDigit) && Int($0).map({ (0...255).contains($0) }) == true }) else { return false }
            let values = octets.compactMap { Int($0) }
            let high = String(format: "%x", (values[0] << 8) | values[1])
            let low = String(format: "%x", (values[2] << 8) | values[3])
            text = String(text[..<colon]) + ":" + high + ":" + low
        }
        let compressed = text.components(separatedBy: "::")
        if compressed.count == 1 {
            let groups = text.split(separator: ":", omittingEmptySubsequences: false)
            return groups.count == 8 && groups.allSatisfy(validHextet)
        }
        guard compressed.count == 2 else { return false }
        let left = compressed[0].split(separator: ":", omittingEmptySubsequences: false)
        let right = compressed[1].split(separator: ":", omittingEmptySubsequences: false)
        guard !left.contains(where: { $0.isEmpty }) && !right.contains(where: { $0.isEmpty }),
              left.allSatisfy(validHextet), right.allSatisfy(validHextet) else { return false }
        return left.count + right.count < 8
    }

    private static func validHextet(_ value: Substring) -> Bool {
        !value.isEmpty && value.utf8.count <= 4 && value.utf8.allSatisfy(isASCIIHex)
    }

    private static func uriCharacters(_ bytes: [UInt8], extra: [UInt8]) -> Bool {
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            if byte == 0x25 {
                let next = bytes.index(after: index)
                guard next < bytes.endIndex else { return false }
                let after = bytes.index(after: next)
                guard after < bytes.endIndex, isASCIIHex(bytes[next]), isASCIIHex(bytes[after]) else { return false }
                index = bytes.index(after: after)
            } else if isASCIIDigit(byte) || isASCIIAlpha(byte) || Array("-._~!$&'()*+,;=").contains(byte) || extra.contains(byte) {
                index = bytes.index(after: index)
            } else {
                return false
            }
        }
        return true
    }

    private static func isASCIIAlpha(_ byte: UInt8) -> Bool { (0x41...0x5a).contains(byte) || (0x61...0x7a).contains(byte) }
    private static func isASCIIDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }
    private static func isASCIIHex(_ byte: UInt8) -> Bool { isASCIIDigit(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte) }
}

/// A stable phone id: the mode plus the backend's own id (`sim:<udid>`,
/// `dev:<udid>`, `vm:<name>`). The CLI and MCP take this string form.
public struct PhoneDeviceID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let mode: PhoneMode
    /// The simulator UDID, the device UDID, or the VM name.
    public let raw: String

    public init(mode: PhoneMode, raw: String) {
        self.mode = mode
        self.raw = raw
    }

    /// Parses `sim:<udid>`, `dev:<udid>` or `vm:<name>`. Nil for any other text.
    public init?(_ text: String) {
        guard let colon = text.firstIndex(of: ":"),
              let mode = PhoneMode(rawValue: String(text[..<colon])) else { return nil }
        let raw = String(text[text.index(after: colon)...])
        guard !raw.isEmpty else { return nil }
        self.init(mode: mode, raw: raw)
    }

    public var description: String { "\(mode.rawValue):\(raw)" }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let id = PhoneDeviceID(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a phone id: \(text)"))
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

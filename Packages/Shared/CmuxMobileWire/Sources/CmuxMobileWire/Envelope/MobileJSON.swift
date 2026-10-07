public import Foundation

/// Any JSON record of either plane: an envelope frame or a channel message.
public enum MobileJSON: Hashable, Sendable {
    case frame(MobileFrame)
    case message(ChannelMessage)

    /// Decodes a record. A `t` that is not a frame type but names a catalog
    /// `message` is a channel message; anything else must be a frame.
    public init(decoding data: Data, catalog: MobileCatalog = .v1) throws {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw MobileWireError(code: "validation.invalid", message: "not JSON")
        }
        try self.init(value: value, catalog: catalog)
    }

    public init(value: JSONValue, catalog: MobileCatalog = .v1) throws {
        if let o = value.objectValue, let t = o["t"]?.stringValue, MobileFrameType(rawValue: t) == nil,
           catalog.message(named: t)?.kind == .message {
            var body = o
            body["t"] = nil
            self = .message(ChannelMessage(name: t, body: body))
        } else {
            self = .frame(try MobileFrame(value: value))
        }
    }

    public var jsonValue: JSONValue {
        get throws {
            switch self {
            case .frame(let f): try f.jsonValue
            case .message(let m): m.jsonValue
            }
        }
    }
}

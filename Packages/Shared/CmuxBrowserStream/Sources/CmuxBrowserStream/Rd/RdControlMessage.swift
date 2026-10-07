public import CmuxMobileWire

/// One rd control message (JSON on stream frame type 1). Browser channels
/// use only `service` (an `rb/1` message as `body`); the rd hello/welcome
/// handshake is replaced by `channel.open`/`channel.opened`.
public enum RdControlMessage: Hashable, Sendable {
    case service(service: String, body: JSONValue)
    /// Any other rd control message, kept as sent.
    case other(JSONValue)

    public static let browserService = "rb/1"

    public init(json: JSONValue) throws(RdWireError) {
        guard let object = json.objectValue, let tag = object["t"]?.stringValue else {
            throw RdWireError("rd control without t")
        }
        if tag == "service" {
            guard let service = object["service"]?.stringValue, let body = object["body"] else {
                throw RdWireError("rd service without service or body")
            }
            self = .service(service: service, body: body)
        } else {
            self = .other(json)
        }
    }

    public var jsonValue: JSONValue {
        switch self {
        case .service(let service, let body):
            .object(["t": .string("service"), "service": .string(service), "body": body])
        case .other(let value):
            value
        }
    }
}

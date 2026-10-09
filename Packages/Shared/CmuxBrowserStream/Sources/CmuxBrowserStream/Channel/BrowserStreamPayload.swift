import CmuxMobileWire
public import Foundation

/// One record payload of a browser channel or its datagram lane: an rd
/// stream frame without its length (A0 3.4), typed.
public enum BrowserStreamPayload: Hashable, Sendable {
    case control(RdControlMessage)
    case datagram(RdDatagramHeader, Data)

    /// An rb message wrapped as rd `service` control.
    public static func rb(_ message: RbControl) -> BrowserStreamPayload {
        .control(.service(service: RdControlMessage.browserService, body: message.jsonValue))
    }

    public init(record payload: Data) throws(RdWireError) {
        let frame: RdStreamFrame
        do {
            frame = try RdStreamFrame(decoding: payload)
        } catch {
            throw RdWireError("rd stream frame: \(error)")
        }
        switch frame.type {
        case .control:
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: frame.data) else {
                throw RdWireError("rd control is not JSON")
            }
            self = .control(try RdControlMessage(json: value))
        case .datagram:
            let (header, body) = try RdDatagramHeader.decode(frame.data)
            self = .datagram(header, body)
        case .bulk:
            throw RdWireError("rd bulk frames are not used on browser channels")
        }
    }

    public func encoded() throws(RdWireError) -> Data {
        switch self {
        case .control(let message):
            guard let data = try? message.jsonValue.canonicalData() else { throw RdWireError("rd control does not encode") }
            return RdStreamFrame(type: .control, data: data).encoded
        case .datagram(let header, let body):
            return RdStreamFrame(type: .datagram, data: header.datagram(payload: body)).encoded
        }
    }

    /// Wraps an already encoded rd datagram.
    public static func encodedDatagram(_ datagram: Data) -> Data {
        RdStreamFrame(type: .datagram, data: datagram).encoded
    }

    /// The rb message, when this is rd `service` control for `rb/1`.
    public var rbControl: RbControl? {
        guard case .control(.service(let service, let body)) = self, service == RdControlMessage.browserService else { return nil }
        return try? RbControl(json: body)
    }
}

import CmuxMobileWire
public import CmuxBrowserStream
public import Foundation

/// One record payload of an `rd` channel or its datagram lane: an rd
/// stream frame without its length (A0 3.4), typed. Control is `desktop/1`
/// service JSON; datagrams are rd video, input, input_ack and feedback.
public enum DesktopPayload: Hashable, Sendable {
    case control(DesktopMessage)
    /// rd control that is not `desktop/1` (kept, ignored by both ends).
    case otherControl(RdControlMessage)
    case datagram(RdDatagramHeader, Data)

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
            let control = try RdControlMessage(json: value)
            if case .service(let service, let body) = control, service == DesktopMessage.service {
                self = .control(try DesktopMessage(json: body))
            } else {
                self = .otherControl(control)
            }
        case .datagram:
            let (header, body) = try RdDatagramHeader.decode(frame.data)
            self = .datagram(header, body)
        case .bulk:
            throw RdWireError("rd bulk frames are not used on rd channels")
        }
    }

    public func encoded() throws(RdWireError) -> Data {
        switch self {
        case .control(let message):
            return try Self.encode(message.rdControl)
        case .otherControl(let control):
            return try Self.encode(control)
        case .datagram(let header, let body):
            return RdStreamFrame(type: .datagram, data: header.datagram(payload: body)).encoded
        }
    }

    /// Wraps an already encoded rd datagram.
    public static func encodedDatagram(_ datagram: Data) -> Data {
        RdStreamFrame(type: .datagram, data: datagram).encoded
    }

    private static func encode(_ control: RdControlMessage) throws(RdWireError) -> Data {
        guard let data = try? control.jsonValue.canonicalData() else { throw RdWireError("rd control does not encode") }
        return RdStreamFrame(type: .control, data: data).encoded
    }
}

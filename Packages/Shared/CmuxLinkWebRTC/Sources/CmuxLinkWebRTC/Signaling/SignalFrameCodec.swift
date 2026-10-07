public import CmuxLinkSignaling
public import CmuxMobileWire
import CmuxLink
import Foundation

/// Maps `SignalMessage` to and from the `cmux.mobile/1` `signal` frame
/// (`families/signal.schema.json`).
public struct SignalFrameCodec: Sendable {
    public init() {}

    public func frame(for message: SignalMessage) -> SignalFrame {
        let kind: SignalKind
        var body: [String: JSONValue] = [:]
        switch message.payload {
        case let .offer(sdp, iceRestart, carrier, auth):
            kind = .offer
            body["sdp"] = .string(sdp)
            body["ice_restart"] = .bool(iceRestart)
            body["carrier"] = .string(carrier.rawValue)
            if let auth { body["auth"] = Self.encode(auth) }
        case let .answer(sdp, auth):
            kind = .answer
            body["sdp"] = .string(sdp)
            if let auth { body["auth"] = Self.encode(auth) }
        case let .ice(candidate):
            kind = .ice
            body["candidate"] = .string(candidate.candidate)
            body["sdp_mid"] = candidate.sdpMid.map(JSONValue.string) ?? .null
            body["sdp_mline_index"] = candidate.sdpMLineIndex.map { .int(Int64($0)) } ?? .null
        case .iceEnd:
            kind = .iceEnd
        case let .bye(reason):
            kind = .bye
            body["reason"] = .string(reason.rawValue)
        }
        return SignalFrame(kind: kind, session: message.session, to: message.to, from: message.from, body: body)
    }

    /// Decodes a relayed frame; nil when the body does not match its kind.
    public func message(from frame: SignalFrame) -> SignalMessage? {
        let body = frame.body
        let payload: SignalPayload
        switch frame.kind {
        case .offer:
            guard case let .string(sdp)? = body["sdp"] else { return nil }
            var iceRestart = false
            if case let .bool(flag)? = body["ice_restart"] { iceRestart = flag }
            var carrier = CarrierKind.webrtc
            if case let .string(name)? = body["carrier"] {
                guard name == CarrierKind.webrtc.rawValue || name == CarrierKind.webrtcWireGuard.rawValue else { return nil }
                carrier = CarrierKind(rawValue: name)
            }
            payload = .offer(sdp: sdp, iceRestart: iceRestart, carrier: carrier, auth: Self.decodeAuth(body["auth"]))
        case .answer:
            guard case let .string(sdp)? = body["sdp"] else { return nil }
            payload = .answer(sdp: sdp, auth: Self.decodeAuth(body["auth"]))
        case .ice:
            guard case let .string(candidate)? = body["candidate"] else { return nil }
            var mid: String?
            if case let .string(value)? = body["sdp_mid"] { mid = value }
            var index: Int?
            if case let .int(value)? = body["sdp_mline_index"] { index = Int(value) }
            payload = .ice(ICECandidateInit(candidate: candidate, sdpMid: mid, sdpMLineIndex: index))
        case .iceEnd:
            payload = .iceEnd
        case .bye:
            guard case let .string(raw)? = body["reason"], let reason = SignalByeReason(rawValue: raw) else { return nil }
            payload = .bye(reason)
        }
        return SignalMessage(session: frame.session, to: frame.to, from: frame.from, payload: payload)
    }

    private static func encode(_ auth: SignalAuth) -> JSONValue {
        .object([
            "key": .string(auth.key.base64EncodedString()),
            "sig": .string(auth.signature.base64EncodedString()),
        ])
    }

    private static func decodeAuth(_ value: JSONValue?) -> SignalAuth? {
        guard case let .object(fields)? = value,
              case let .string(key)? = fields["key"], let keyData = Data(base64Encoded: key),
              case let .string(sig)? = fields["sig"], let sigData = Data(base64Encoded: sig)
        else { return nil }
        return SignalAuth(key: keyData, signature: sigData)
    }
}

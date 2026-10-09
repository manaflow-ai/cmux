public import Foundation

/// One cmux.mobile/1 JSON frame. Control-plane frames are the cmux.wire/1
/// shapes (backend/packages/ownership `types.ts`); `hello`, `read`, `signal`
/// and `channel.*` are new. Unknown members are ignored on decode.
public enum MobileFrame: Hashable, Sendable {
    case hello(HelloFrame)
    case helloOK(HelloOKFrame)
    case welcome(WelcomeFrame)
    case subscribe(SubscribeFrame)
    case unsubscribe(UnsubscribeFrame)
    case snapshotRequest(SnapshotRequestFrame)
    case op(OpFrame)
    case read(ReadFrame)
    case readResult(ReadResultFrame)
    case result(ResultFrame)
    case reject(RejectFrame)
    case settled(SettledFrame)
    case event(EventFrame)
    case snapshot(SnapshotFrame)
    case presenceSet(PresenceSetFrame)
    case signal(SignalFrame)
    case error(ErrorFrame)
    case channelOpen(ChannelOpenFrame)
    case channelOpened(ChannelOpenedFrame)
    case channelRefused(ChannelRefusedFrame)
    case channelClose(ChannelCloseFrame)
    case channelClosed(ChannelClosedFrame)

    public init(decoding data: Data) throws {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw MobileWireError(code: "validation.invalid", message: "not JSON")
        }
        try self.init(value: value)
    }

    /// Decodes a frame; throws `proto.unknown_frame` for an unknown `t` and
    /// `validation.invalid` for a known `t` with missing or mistyped members.
    public init(value: JSONValue) throws {
        guard let raw = value["t"]?.stringValue, let type = MobileFrameType(rawValue: raw) else {
            throw MobileWireError(code: "proto.unknown_frame", message: "unknown frame \(value["t"]?.stringValue ?? "<none>")")
        }
        do {
            self = try Self.decode(type, value)
        } catch {
            throw MobileWireError(code: "validation.invalid", message: "bad \(raw) frame: \(error)")
        }
        if type == .hello || type == .helloOK, value["proto"]?.stringValue != HelloFrame.proto {
            throw MobileWireError(code: "proto.version_unsupported", message: "proto must be \(HelloFrame.proto)")
        }
    }

    public var type: MobileFrameType {
        switch self {
        case .hello: .hello
        case .helloOK: .helloOK
        case .welcome: .welcome
        case .subscribe: .subscribe
        case .unsubscribe: .unsubscribe
        case .snapshotRequest: .snapshotRequest
        case .op: .op
        case .read: .read
        case .readResult: .readResult
        case .result: .result
        case .reject: .reject
        case .settled: .settled
        case .event: .event
        case .snapshot: .snapshot
        case .presenceSet: .presenceSet
        case .signal: .signal
        case .error: .error
        case .channelOpen: .channelOpen
        case .channelOpened: .channelOpened
        case .channelRefused: .channelRefused
        case .channelClose: .channelClose
        case .channelClosed: .channelClosed
        }
    }

    /// The catalog message this frame carries: the op of `op`, `read` and
    /// `event`, the kind of `channel.open`, `signal.<kind>` of `signal`.
    public var messageName: String? {
        switch self {
        case .op(let f): f.op
        case .read(let f): f.op
        case .event(let f): f.op
        case .channelOpen(let f): f.kind.rawValue
        case .signal(let f): "signal.\(f.kind.rawValue)"
        default: nil
        }
    }

    /// The frame as a JSON object, `t` included.
    public var jsonValue: JSONValue {
        get throws {
            guard case .object(var o) = try JSONValue(encoding: payload) else {
                throw MobileWireError(code: "validation.invalid", message: "frame did not encode to an object")
            }
            o["t"] = .string(type.rawValue)
            return .object(o)
        }
    }

    /// Canonical JSON bytes of the frame.
    public func encoded() throws -> Data {
        try jsonValue.canonicalData()
    }

    private var payload: any Encodable {
        switch self {
        case .hello(let f): f
        case .helloOK(let f): f
        case .welcome(let f): f
        case .subscribe(let f): f
        case .unsubscribe(let f): f
        case .snapshotRequest(let f): f
        case .op(let f): f
        case .read(let f): f
        case .readResult(let f): f
        case .result(let f): f
        case .reject(let f): f
        case .settled(let f): f
        case .event(let f): f
        case .snapshot(let f): f
        case .presenceSet(let f): f
        case .signal(let f): f
        case .error(let f): f
        case .channelOpen(let f): f
        case .channelOpened(let f): f
        case .channelRefused(let f): f
        case .channelClose(let f): f
        case .channelClosed(let f): f
        }
    }

    private static func decode(_ type: MobileFrameType, _ value: JSONValue) throws -> MobileFrame {
        switch type {
        case .hello: .hello(try value.decode(as: HelloFrame.self))
        case .helloOK: .helloOK(try value.decode(as: HelloOKFrame.self))
        case .welcome: .welcome(try value.decode(as: WelcomeFrame.self))
        case .subscribe: .subscribe(try value.decode(as: SubscribeFrame.self))
        case .unsubscribe: .unsubscribe(try value.decode(as: UnsubscribeFrame.self))
        case .snapshotRequest: .snapshotRequest(try value.decode(as: SnapshotRequestFrame.self))
        case .op: .op(try value.decode(as: OpFrame.self))
        case .read: .read(try value.decode(as: ReadFrame.self))
        case .readResult: .readResult(try value.decode(as: ReadResultFrame.self))
        case .result: .result(try value.decode(as: ResultFrame.self))
        case .reject: .reject(try value.decode(as: RejectFrame.self))
        case .settled: .settled(try value.decode(as: SettledFrame.self))
        case .event: .event(try value.decode(as: EventFrame.self))
        case .snapshot: .snapshot(try value.decode(as: SnapshotFrame.self))
        case .presenceSet: .presenceSet(try value.decode(as: PresenceSetFrame.self))
        case .signal: .signal(try value.decode(as: SignalFrame.self))
        case .error: .error(try value.decode(as: ErrorFrame.self))
        case .channelOpen: .channelOpen(try value.decode(as: ChannelOpenFrame.self))
        case .channelOpened: .channelOpened(try value.decode(as: ChannelOpenedFrame.self))
        case .channelRefused: .channelRefused(try value.decode(as: ChannelRefusedFrame.self))
        case .channelClose: .channelClose(try value.decode(as: ChannelCloseFrame.self))
        case .channelClosed: .channelClosed(try value.decode(as: ChannelClosedFrame.self))
        }
    }
}

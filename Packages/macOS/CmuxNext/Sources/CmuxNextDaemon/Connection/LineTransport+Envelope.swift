import CmuxNextCompat
import CmuxNextIPC
import Foundation

extension LineTransport {
    /// ``EventHandler`` with the line's envelope `cause` (cmux-tui/spec/events.md), read in the same
    /// parse as its routing fields; nil from a daemon that does not send one.
    typealias CausedEventHandler = @Sendable (_ name: String, _ line: Data, _ index: UInt64, _ cause: String?) -> Void

    /// Starts the reader thread. Call once.
    func start(onEvent: @escaping EventHandler, onClose: @escaping CloseHandler) {
        start(onCausedEvent: { name, line, index, _ in onEvent(name, line, index) }, onClose: onClose)
    }

    /// The wire kind of an EVENT frame (cmux-ipc frame.rs `FrameKind::Event`).
    static let eventFrameKind: UInt8 = 3

    /// Counts `streamID`'s lines as stream-0 events until its `stream_end`; call before the request that
    /// opens it, ``endControlSequence(streamID:)`` if that fails. With `mintingFrameStream`, it also takes
    /// a client stream id for it (``mintFrameStream()``) and returns it, for the open's `stream`: the
    /// stream's EVENT frames on that id are then its items, routed by header alone
    /// (``routeStreamItem(_:onEvent:)``, p05-ipc-145). Nil when it took none.
    @discardableResult
    func routeOnControlSequence(streamID: String, mintingFrameStream: Bool = false) -> UInt16? {
        state.withLock { state -> UInt16? in
            state.controlStreams.insert(streamID)
            guard mintingFrameStream, let id = state.frameStreams.mint() else { return nil }
            state.controlFrameStreams[id] = streamID
            return id
        }
    }

    /// Stops routing `streamID` and frees its client stream id: its open failed, or its end was read.
    func endControlSequence(streamID: String) {
        state.withLock { $0.endControlSequence(streamID: streamID) }
    }

    /// Takes a client stream id (u16, never 0) no open stream of this connection holds, or nil when all
    /// 65,535 are held. Every client stream id of the connection comes from here, so two kinds of
    /// stream never collide; it is the connection's again after ``releaseFrameStream(_:)``, once the
    /// stream's end was read (the daemon frees it when it queues that end, spec/events.md "Attach streams").
    func mintFrameStream() -> UInt16? { state.withLock { $0.frameStreams.mint() } }

    /// Gives back a client stream id from ``mintFrameStream()`` whose stream ended.
    func releaseFrameStream(_ id: UInt16) { _ = state.withLock { $0.frameStreams.release(id) } }

    /// Where one `cmux.protocol/2` stream line goes (`route`).
    enum StreamRoute {
        /// A control-sequence stream (`session.events`): counted with the raw events.
        case control
        /// The dedicated connection's stream handler (`SessionJournalRead`).
        case handler(@Sendable (_ streamID: String, _ line: Data) -> Void)
        /// A stream nobody registered (one whose open failed): dropped, so it never
        /// reaches the store under another event's sequence.
        case unrouted
    }

    /// Routing fields of a raw protocol line or a `cmux.protocol/2`
    /// response. Resource responses carry the request id as a decimal
    /// string and a structured `error` object `{code, message, details,
    /// retryable}`, kept whole for the caller.
    struct Envelope: Decodable {
        var id: UInt64?
        var ok: Bool?
        var event: String?
        var error: String?
        var errorCode: String?
        /// `stream_item` or `stream_end` of a `cmux.protocol/2` stream.
        var type: String?
        var streamID: String?
        var errorDetails: JSONValue?
        var retryable: Bool?
        /// An event's `cause` (`frontend`, `program`, `automation`); scheduling only.
        var cause: String?

        enum CodingKeys: String, CodingKey {
            case id, ok, event, error, type, reason, retryable, data, cause
            case errorCode = "error_code"
            case streamID = "stream_id"
        }

        /// The routing fields alone (``LineRouteScan/envelope``); a reply that is not `ok:true` is
        /// decoded whole for its error fields.
        init(id: UInt64?, ok: Bool?, event: String?, type: String?, streamID: String?, cause: String?) {
            (self.id, self.ok, self.event, self.type, self.streamID, self.cause) = (id, ok, event, type, streamID, cause)
        }

        private struct ResourceError: Decodable {
            var code: String?
            var message: String?
            var details: JSONValue?
            var retryable: JSONValue?
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let number = try? c.decodeIfPresent(UInt64.self, forKey: .id) {
                id = number
            } else if let text = try? c.decodeIfPresent(String.self, forKey: .id) {
                id = UInt64(text, radix: 10)
            }
            ok = try? c.decodeIfPresent(Bool.self, forKey: .ok)
            (event, streamID) = (try? c.decodeIfPresent(String.self, forKey: .event), try? c.decodeIfPresent(String.self, forKey: .streamID))
            if event != nil { cause = try? c.decodeIfPresent(String.self, forKey: .cause) }
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            errorCode = try? c.decodeIfPresent(String.self, forKey: .errorCode)
            if let text = try? c.decodeIfPresent(String.self, forKey: .error) {
                error = text
                // A raw conversation reject carries its stable `reason` and
                // `retryable` next to `error_code` (home.md section 2,
                // home-cloud-proxy.md section 6); `details` holds the reason.
                if let reason = try? c.decodeIfPresent(String.self, forKey: .reason) {
                    errorDetails = .object(["reason": .string(reason)])
                } else if let data = try? c.decodeIfPresent(JSONValue.self, forKey: .data), case .object = data {
                    // A typed refusal's facts (`agent_session.needs_keyed_start`, cx-0w0jj).
                    errorDetails = data
                }
                retryable = try? c.decodeIfPresent(Bool.self, forKey: .retryable)
            } else if let structured = try? c.decodeIfPresent(ResourceError.self, forKey: .error) {
                error = structured.message ?? structured.code
                errorCode = errorCode ?? structured.code
                (errorDetails, retryable) = (structured.details, structured.retryable?.boolValue)
            }
        }
    }
}

extension LineTransport.State {
    /// Stops routing control stream `streamID` and frees the client stream id it was opened on.
    mutating func endControlSequence(streamID: String) {
        controlStreams.remove(streamID)
        guard let id = controlFrameStreams.first(where: { $0.value == streamID })?.key else { return }
        controlFrameStreams[id] = nil
        frameStreams.release(id)
    }
}

/// The client stream ids (u16) a connection holds. Ids are taken round-robin from 1, so an id just freed
/// is the last one taken again, as HTTP/2 never reuses a stream id on a connection (RFC 9113 section 5.1.1).
struct FrameStreamIDs: Sendable {
    /// Ids 1 through 65,535: 0 is the control stream.
    static let capacity = 65_535

    private var held: Set<UInt16> = []
    private var next: UInt16 = 1

    /// A free id, now held; nil when every id is held.
    mutating func mint() -> UInt16? {
        guard held.count < Self.capacity else { return nil }
        // Ends: fewer than UInt16.max ids are held, so a free one is at most UInt16.max steps away.
        while held.contains(next) { advance() }
        let id = next
        held.insert(id)
        advance()
        return id
    }

    /// Frees `id`; false when it was not held.
    @discardableResult
    mutating func release(_ id: UInt16) -> Bool { held.remove(id) != nil }

    /// Whether `id` is held.
    func holds(_ id: UInt16) -> Bool { held.contains(id) }

    private mutating func advance() { next = next == UInt16.max ? 1 : next + 1 }
}

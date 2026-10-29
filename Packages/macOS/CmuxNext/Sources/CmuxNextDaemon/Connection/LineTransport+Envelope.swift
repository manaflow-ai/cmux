import Foundation

extension LineTransport {
    /// ``EventHandler`` with the line's envelope `cause` (cmux-tui/spec/events.md), read in the same
    /// parse as its routing fields; nil from a daemon that does not send one.
    typealias CausedEventHandler = @Sendable (_ name: String, _ line: Data, _ index: UInt64, _ cause: String?) -> Void

    /// Starts the reader thread. Call once. `dispatch`: see ``start(dispatch:onCausedEvent:onClose:)``.
    func start(dispatch: EventDispatch = .control, onEvent: @escaping EventHandler, onClose: @escaping CloseHandler) {
        start(dispatch: dispatch, onCausedEvent: { name, line, index, _ in onEvent(name, line, index) }, onClose: onClose)
    }

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
        /// The client-minted attach stream an event belongs to (attach-streams-v1); nil on stream 0.
        var stream: UInt16?

        enum CodingKeys: String, CodingKey {
            case id, ok, event, error, type, reason, retryable, data, cause, stream
            case errorCode = "error_code"
            case streamID = "stream_id"
        }

        /// The routing fields alone (``LineRouteScan/envelope``); a reply that is not `ok:true` is
        /// decoded whole for its error fields.
        init(id: UInt64?, ok: Bool?, event: String?, type: String?, streamID: String?, cause: String?, stream: UInt16? = nil) {
            (self.id, self.ok, self.event, self.type, self.streamID, self.cause) = (id, ok, event, type, streamID, cause)
            self.stream = stream
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
            if event != nil {
                cause = try? c.decodeIfPresent(String.self, forKey: .cause)
                stream = try? c.decodeIfPresent(UInt16.self, forKey: .stream)
            }
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

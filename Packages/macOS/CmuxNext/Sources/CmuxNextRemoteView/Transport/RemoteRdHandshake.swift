import Foundation

/// The viewer's side of the `cmux.rd/1` session setup. The rules live in Rust
/// (cmux-rd-ffi `view/handshake.rs`, ops `handshake.*` over `cmux_rd_view_call`): hello and
/// start go out, then the host answers welcome and started (or refused); ended closes the
/// session; every other order is a protocol error and ends the session. This type keeps the
/// Rust state and reads its phase back.
public nonisolated struct RemoteRdHandshake: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case awaitingWelcome
        case awaitingStarted
        case streaming(session: UInt64)
        case ended(RemoteSessionEnd)
    }

    public private(set) var phase: Phase = .awaitingWelcome
    public private(set) var welcome: RemoteRdWelcome?
    /// The service the hello asked for; welcome must name the same one.
    public let service: String
    /// True after the viewer sent stop: the host's ended then means "stopped by viewer".
    public private(set) var stopSent = false
    /// The Rust `Handshake`, as JSON.
    private var state: Data

    public init(service: String) {
        self.service = service
        let state = RemoteRdView.call(["op": "handshake.new", "service": service])
            ?? ["service": service]
        self.state = (try? JSONSerialization.data(withJSONObject: state)) ?? Data()
    }

    /// The pane-facing state of the current phase.
    public var sessionState: RemoteSessionState {
        switch phase {
        case .awaitingWelcome, .awaitingStarted: .connecting
        case .streaming: .streaming
        case let .ended(end): .ended(end)
        }
    }

    public var isEnded: Bool {
        if case .ended = phase { return true }
        return false
    }

    /// Applies one control message from the host (the frame payload).
    public mutating func receive(_ json: Data) {
        guard !isEnded, let message = try? JSONSerialization.jsonObject(with: json) else { return }
        apply("handshake.receive", ["message": message])
    }

    /// What the host's `ended` means: `cmux rd serve` ends a session it could not run with
    /// `failed: <error>` (cmux-rd-host `serve.rs`), and that error is kept for the card; any
    /// other reason (stopped, the viewer left) is the host stopping.
    public static func hostEnd(_ reason: String) -> RemoteSessionEnd {
        RemoteRdView.sessionEnd(RemoteRdView.call(["op": "handshake.hostEnd", "reason": reason]))
            ?? .hostStoppedSharing
    }

    /// The viewer sent stop.
    public mutating func viewerStopped() {
        apply("handshake.viewerStopped", [:])
    }

    /// The carrier closed or failed.
    public mutating func connectionClosed() {
        guard !isEnded else { return }
        apply("handshake.closed", [:])
    }

    /// Runs one `handshake.*` op on the state and reads the next state back.
    private mutating func apply(_ op: String, _ fields: [String: Any]) {
        guard let current = try? JSONSerialization.jsonObject(with: state) else { return }
        var request = fields
        request["op"] = op
        request["state"] = current
        guard let next = RemoteRdView.call(request)?["state"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: next) else { return }
        state = data
        stopSent = next["stopSent"] as? Bool ?? false
        if let phase = Self.phase(next["phase"]) { self.phase = phase }
        welcome = (next["welcome"] as? [String: Any]).flatMap { welcome in
            (try? JSONSerialization.data(withJSONObject: welcome))
                .flatMap { try? JSONDecoder().decode(RemoteRdWelcome.self, from: $0) }
        }
    }

    /// A Rust `Phase` (`{"kind": ...}`).
    private static func phase(_ value: Any?) -> Phase? {
        guard let object = value as? [String: Any], let kind = object["kind"] as? String else { return nil }
        switch kind {
        case "awaitingWelcome": return .awaitingWelcome
        case "awaitingStarted": return .awaitingStarted
        case "streaming": return (object["session"] as? NSNumber).map { .streaming(session: $0.uint64Value) }
        case "ended": return RemoteRdView.sessionEnd(object["end"]).map { .ended($0) }
        default: return nil
        }
    }
}

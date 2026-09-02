import Foundation

/// One byte-oriented event delivered by a cmux-tui legacy `attach-surface` stream.
///
/// The native cloud pane consumes these events as terminal bytes. It deliberately
/// does not contain a rendered-cell representation: libghostty remains the only
/// renderer in a native pane.
enum CloudTuiManualIOFrame: Equatable, Sendable {
    case snapshot(surfaceID: UInt64, columns: Int, rows: Int, bytes: Data)
    case output(surfaceID: UInt64, bytes: Data)
    case resized(surfaceID: UInt64, columns: Int, rows: Int, bytes: Data)
    case detached(surfaceID: UInt64)
    case overflow(surfaceID: UInt64?)
    case response(
        requestID: UInt64,
        ok: Bool,
        lease: String?,
        capabilities: [String],
        outcome: String?,
        accepted: Bool?,
        error: String?
    )
}

/// Decodes one newline-delimited cmux-tui protocol message into a byte event.
///
/// The decoder is intentionally stateless. A socket reader owns line framing;
/// this value only validates the event discriminator and base64 payload.
struct CloudTuiManualIOFrameDecoder: Sendable {
    /// Decodes a complete JSON object line, returning `nil` for malformed or
    /// unrelated messages.
    func decode(_ line: Data) -> CloudTuiManualIOFrame? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return nil
        }
        if let event = object["event"] as? String {
            return decodeEvent(event, object: object)
        }
        guard let requestID = Self.uint64(object["id"]),
              let ok = object["ok"] as? Bool else {
            return nil
        }
        let responseData = object["data"] as? [String: Any]
        return .response(
            requestID: requestID,
            ok: ok,
            lease: (responseData?["lease"] as? String) ?? (object["lease"] as? String),
            capabilities: (responseData?["capabilities"] as? [String]) ?? [],
            outcome: responseData?["outcome"] as? String,
            accepted: responseData?["accepted"] as? Bool,
            error: object["error"] as? String
        )
    }

    private func decodeEvent(_ event: String, object: [String: Any]) -> CloudTuiManualIOFrame? {
        guard let surfaceID = Self.uint64(object["surface"]) else {
            if event == "overflow" { return .overflow(surfaceID: nil) }
            return nil
        }
        switch event {
        case "vt-state":
            guard let size = Self.size(from: object), let bytes = Self.bytes(from: object["data"]) else { return nil }
            return .snapshot(surfaceID: surfaceID, columns: size.columns, rows: size.rows, bytes: bytes)
        case "output":
            guard let bytes = Self.bytes(from: object["data"]) else { return nil }
            return .output(surfaceID: surfaceID, bytes: bytes)
        case "resized":
            guard let size = Self.size(from: object),
                  let bytes = Self.bytes(
                      from: (object["replay"] as? String) ?? (object["data"] as? String)
                  ) else { return nil }
            return .resized(surfaceID: surfaceID, columns: size.columns, rows: size.rows, bytes: bytes)
        case "detached":
            return .detached(surfaceID: surfaceID)
        case "overflow":
            return .overflow(surfaceID: surfaceID)
        default:
            return nil
        }
    }

    private static func size(from object: [String: Any]) -> (columns: Int, rows: Int)? {
        guard let columns = uint64(object["cols"]),
              let rows = uint64(object["rows"]),
              columns > 0,
              rows > 0,
              columns <= UInt64(Int.max),
              rows <= UInt64(Int.max) else {
            return nil
        }
        return (Int(columns), Int(rows))
    }

    private static func bytes(from value: Any?) -> Data? {
        guard let encoded = value as? String else { return nil }
        return Data(base64Encoded: encoded)
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber {
            return number.uint64Value
        }
        if let string = value as? String {
            return UInt64(string)
        }
        return nil
    }
}

/// Builds the private JSON commands used by a native cloud manual-I/O pane.
///
/// These commands are transport operations only. They never ask cmux-tui to
/// render a viewport; the host consumes the resulting raw PTY bytes.
enum CloudTuiManualIOCommand {
    /// cmux-tui's terminal geometry clamp (the protocol's uint16 values are
    /// additionally bounded to keep pathological panes from exhausting the
    /// remote PTY).
    static let maximumGridDimension = 10_000
    /// The capability understood by protocol-v9+ servers that returns a
    /// connection-owned lease for each byte attachment.
    static let viewAttachmentLeaseCapability = "view-attachment-lease-v1"

    /// The capability understood by protocol-v9+ servers that allows a
    /// client to retire one attachment without dropping the whole socket.
    static let viewAttachmentDetachCapability = "view-attachment-detach-v1"

    /// Begins the protocol handshake so optional attach fields are sent only
    /// when the daemon advertises the matching capability.
    static func identify(requestID: UInt64 = 1) -> [String: Any] {
        [
            "id": requestID,
            "cmd": "identify",
        ]
    }

    /// Advertises this connection as the native Ghostty mirror.  The server
    /// only adds capabilities it recognizes, so sending these to an older
    /// daemon is safe and leaves the byte attach fallback available.
    static func setClientInfo(
        name: String,
        kind: String,
        requestID: UInt64 = 1
    ) -> [String: Any] {
        [
            "id": requestID,
            "cmd": "set-client-info",
            "name": name,
            "kind": kind,
            "capabilities": [
                viewAttachmentLeaseCapability,
                viewAttachmentDetachCapability,
            ],
        ]
    }

    /// Claims this connection as the terminal's geometry owner.
    ///
    /// A `resize-surface` report is sent before this command.  The daemon
    /// requires a reported size before it can promote a client, and the
    /// explicit claim is what makes a native pane's grid authoritative rather
    /// than merely a passive viewport hint.
    static func claimGeometry(surfaceID: UInt64, requestID: UInt64 = 1) -> [String: Any] {
        [
            "id": requestID,
            "cmd": "set-client-sizing",
            "surface": surfaceID,
            "enabled": true,
            "exclusive": true,
        ]
    }

    /// Opens a byte attach stream for one numeric cmux-tui surface.
    static func attach(
        surfaceID: UInt64,
        columns: Int? = nil,
        rows: Int? = nil,
        requestID: UInt64 = 1
    ) -> [String: Any]? {
        var command: [String: Any] = [
            "id": requestID,
            "cmd": "attach-surface",
            "surface": surfaceID,
        ]
        switch (columns, rows) {
        case (nil, nil):
            break
        case let (.some(columns), .some(rows))
            where columns > 0 && rows > 0
                && columns <= maximumGridDimension
                && rows <= maximumGridDimension:
            command["cols"] = columns
            command["rows"] = rows
        default:
            return nil
        }
        return command
    }

    /// Writes raw input bytes to the remote PTY.
    static func input(surfaceID: UInt64, bytes: Data, requestID: UInt64 = 1) -> [String: Any] {
        [
            "id": requestID,
            "cmd": "send",
            "surface": surfaceID,
            "bytes": bytes.base64EncodedString(),
        ]
    }

    /// Sends one semantic key chord through the remote terminal's key encoder.
    static func namedKey(surfaceID: UInt64, key: String, requestID: UInt64 = 1) -> [String: Any] {
        [
            "id": requestID,
            "cmd": "send-key",
            "surface": surfaceID,
            "keys": [key],
        ]
    }

    /// Reports the native pane's current cell grid to the remote PTY.
    static func resize(surfaceID: UInt64, columns: Int, rows: Int, requestID: UInt64 = 1) -> [String: Any] {
        [
            "id": requestID,
            "cmd": "resize-surface",
            "surface": surfaceID,
            "cols": min(max(columns, 1), maximumGridDimension),
            "rows": min(max(rows, 1), maximumGridDimension),
        ]
    }

    /// Reports a grid for this exact leased attach stream. Lease fencing keeps a
    /// delayed resize from changing a replacement view after reconnect.
    static func resizeAttachedView(
        surfaceID: UInt64,
        lease: String,
        columns: Int,
        rows: Int,
        requestID: UInt64 = 1
    ) -> [String: Any]? {
        guard !lease.isEmpty,
              (1...maximumGridDimension).contains(columns),
              (1...maximumGridDimension).contains(rows) else {
            return nil
        }
        return [
            "id": requestID,
            "cmd": "resize-attached-view",
            "surface": surfaceID,
            "lease": lease,
            "cols": columns,
            "rows": rows,
        ]
    }

    /// Releases this connection's terminal-size report while the native pane
    /// is hidden. The remote PTY keeps its last authoritative grid frozen
    /// until a visible client claims it again.
    static func releaseSizing(surfaceID: UInt64, requestID: UInt64 = 0) -> [String: Any] {
        [
            "id": requestID,
            "cmd": "release-surface-size",
            "surface": surfaceID,
        ]
    }

    /// Removes this exact attach stream's size contribution while retaining
    /// the stream for cached output. The server treats a repeated release as
    /// an idempotent no-op for the same lease.
    static func releaseAttachedViewSize(
        surfaceID: UInt64,
        lease: String,
        requestID: UInt64 = 0
    ) -> [String: Any]? {
        guard !lease.isEmpty else { return nil }
        return [
            "id": requestID,
            "cmd": "release-attached-view-size",
            "surface": surfaceID,
            "lease": lease,
        ]
    }

    /// Explicitly detaches one legacy attachment. Closing the connection is the
    /// fallback for older servers; this command is useful for protocol fixtures.
    static func detach(surfaceID: UInt64, requestID: UInt64 = 1) -> [String: Any] {
        [
            "id": requestID,
            "cmd": "detach-surface",
            "surface": surfaceID,
        ]
    }

    /// Retires a capability-negotiated attachment while keeping the control
    /// socket usable for any other future view.
    static func detachAttachedView(
        surfaceID: UInt64,
        lease: String,
        requestID: UInt64 = 1
    ) -> [String: Any] {
        [
            "id": requestID,
            "cmd": "detach-attached-view",
            "surface": surfaceID,
            "lease": lease,
        ]
    }

    /// Serializes a command as one newline-delimited protocol message.
    static func line(_ command: [String: Any]) -> Data? {
        guard let data = try? JSONSerialization.data(withJSONObject: command) else { return nil }
        return data + Data([0x0A])
    }
}

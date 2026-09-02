import Foundation

/// Builds the private JSON commands used by a native cloud manual-I/O pane.
///
/// These commands are transport operations only. They never ask cmux-tui to
/// render a viewport; the host consumes the resulting raw PTY bytes.
struct CloudTuiManualIOCommand: Sendable {
    /// cmux-tui's terminal geometry clamp (the protocol's uint16 values are
    /// additionally bounded to keep pathological panes from exhausting the
    /// remote PTY).
    let maximumGridDimension: Int

    /// Creates a command builder with the daemon's documented grid bound.
    ///
    /// - Parameter maximumGridDimension: Upper bound used when validating
    ///   caller-provided cell dimensions. Tests may inject a smaller bound to
    ///   exercise rejection without opening a socket.
    init(maximumGridDimension: Int = 10_000) {
        self.maximumGridDimension = max(1, maximumGridDimension)
    }
    /// The capability understood by protocol-v9+ servers that returns a
    /// connection-owned lease for each byte attachment.
    let viewAttachmentLeaseCapability = "view-attachment-lease-v1"

    /// The capability understood by protocol-v9+ servers that allows a
    /// client to retire one attachment without dropping the whole socket.
    let viewAttachmentDetachCapability = "view-attachment-detach-v1"

    /// Begins the protocol handshake so optional attach fields are sent only
    /// when the daemon advertises the matching capability.
    func identify(requestID: UInt64 = 1) -> [String: Any] {
        [
            "id": requestID,
            "cmd": "identify",
        ]
    }

    /// Advertises this connection as the native Ghostty mirror.  The server
    /// only adds capabilities it recognizes, so sending these to an older
    /// daemon is safe and leaves the byte attach fallback available.
    func setClientInfo(
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
    func claimGeometry(surfaceID: UInt64, requestID: UInt64 = 1) -> [String: Any] {
        [
            "id": requestID,
            "cmd": "set-client-sizing",
            "surface": surfaceID,
            "enabled": true,
            "exclusive": true,
        ]
    }

    /// Opens a byte attach stream for one numeric cmux-tui surface.
    func attach(
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
    func input(surfaceID: UInt64, bytes: Data, requestID: UInt64 = 1) -> [String: Any] {
        [
            "id": requestID,
            "cmd": "send",
            "surface": surfaceID,
            "bytes": bytes.base64EncodedString(),
        ]
    }

    /// Sends one semantic key chord through the remote terminal's key encoder.
    func namedKey(surfaceID: UInt64, key: String, requestID: UInt64 = 1) -> [String: Any] {
        [
            "id": requestID,
            "cmd": "send-key",
            "surface": surfaceID,
            "keys": [key],
        ]
    }

    /// Reports the native pane's current cell grid to the remote PTY.
    func resize(surfaceID: UInt64, columns: Int, rows: Int, requestID: UInt64 = 1) -> [String: Any] {
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
    func resizeAttachedView(
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
    func releaseSizing(surfaceID: UInt64, requestID: UInt64 = 0) -> [String: Any] {
        [
            "id": requestID,
            "cmd": "release-surface-size",
            "surface": surfaceID,
        ]
    }

    /// Removes this exact attach stream's size contribution while retaining
    /// the stream for cached output. The server treats a repeated release as
    /// an idempotent no-op for the same lease.
    func releaseAttachedViewSize(
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
    func detach(surfaceID: UInt64, requestID: UInt64 = 1) -> [String: Any] {
        [
            "id": requestID,
            "cmd": "detach-surface",
            "surface": surfaceID,
        ]
    }

    /// Retires a capability-negotiated attachment while keeping the control
    /// socket usable for any other future view.
    func detachAttachedView(
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
    func line(_ command: [String: Any]) -> Data? {
        guard let data = try? JSONSerialization.data(withJSONObject: command) else { return nil }
        return data + Data([0x0A])
    }
}

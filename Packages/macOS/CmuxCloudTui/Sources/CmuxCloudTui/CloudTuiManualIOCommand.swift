import CmuxTerminalSizing
import Foundation

/// Builds private transport commands for a native Cloud Ghostty byte mirror.
public struct CloudTuiManualIOCommand: Sendable {
    /// cmux-tui's terminal geometry clamp (the protocol's uint16 values are
    /// additionally bounded to keep pathological panes from exhausting the
    /// remote PTY).
    public let maximumGridDimension: Int

    /// Creates a command builder with the daemon's documented grid bound.
    ///
    /// - Parameter maximumGridDimension: Upper bound used when validating
    ///   caller-provided cell dimensions. Tests may inject a smaller bound to
    ///   exercise rejection without opening a socket.
    public init(maximumGridDimension: Int = 10_000) {
        self.maximumGridDimension = max(1, maximumGridDimension)
    }
    /// The capability understood by protocol-v9+ servers that returns a
    /// connection-owned lease for each byte attachment.
    public let viewAttachmentLeaseCapability = "view-attachment-lease-v1"

    /// The capability understood by protocol-v9+ servers that allows a
    /// client to retire one attachment without dropping the whole socket.
    public let viewAttachmentDetachCapability = "view-attachment-detach-v1"

    /// Begins the protocol handshake so optional attach fields are sent only
    /// when the daemon advertises the matching capability.
    public func identify(requestID: UInt64 = 1) -> [String: Any] {
        [
            "id": requestID,
            "cmd": "identify",
        ]
    }

    /// A round trip that proves the control connection is alive. Every daemon
    /// answers it; the watchdog sends it when an attached stream has carried
    /// no frame for a while.
    public func ping(requestID: UInt64 = 1) -> [String: Any] {
        [
            "id": requestID,
            "cmd": "ping",
        ]
    }

    /// Advertises this connection as the native Ghostty mirror.  The server
    /// only adds capabilities it recognizes, so sending these to an older
    /// daemon is safe and leaves the byte attach fallback available.
    ///
    /// - Parameters:
    ///   - name: human-readable client name.
    ///   - kind: client kind.
    ///   - identity: the verified participant identity for shared sizing
    ///     (`user_id`, `display_name`, `device_kind`, `device_name`). Only
    ///     sent when the daemon advertised ``sharedSizingCapability``.
    ///   - requestID: correlation id.
    public func setClientInfo(
        name: String,
        kind: String,
        identity: TerminalSizingParticipant? = nil,
        requestID: UInt64 = 1
    ) -> [String: Any] {
        var command: [String: Any] = [
            "id": requestID,
            "cmd": "set-client-info",
            "name": name,
            "kind": kind,
            "capabilities": [
                viewAttachmentLeaseCapability,
                viewAttachmentDetachCapability,
                "terminal-color-overrides-v1",
                sharedSizingCapability,
            ],
        ]
        if let identity {
            for (key, value) in identityObject(identity) { command[key] = value }
        }
        return command
    }

    /// The daemon capability for shared terminal sizing
    /// (`docs/shared-terminal-sizing.md`).
    public let sharedSizingCapability = "shared-sizing-v1"

    /// Creates or updates a relay sub-view (a phone viewing this Mac's mirror).
    ///
    /// - Parameters:
    ///   - surfaceID: the numeric cmux-tui surface.
    ///   - view: relay-scoped key, `mobile:<client_id>`.
    ///   - identity: the phone's identity; its viewport is sent as `cols`/`rows`.
    ///   - requestID: correlation id.
    /// - Returns: the command, or `nil` without a valid viewport.
    public func resizeRelayView(
        surfaceID: UInt64,
        view: String,
        identity: TerminalSizingParticipant,
        requestID: UInt64 = 1
    ) -> [String: Any]? {
        guard !view.isEmpty, let viewport = identity.viewport,
              (1...maximumGridDimension).contains(viewport.cols),
              (1...maximumGridDimension).contains(viewport.rows) else { return nil }
        return [
            "id": requestID,
            "cmd": "resize-attached-view",
            "surface": surfaceID,
            "view": view,
            "identity": identityObject(identity),
            "cols": viewport.cols,
            "rows": viewport.rows,
        ]
    }

    /// Retires a relay sub-view (the phone left or disconnected).
    public func detachRelayView(surfaceID: UInt64, view: String, requestID: UInt64 = 0) -> [String: Any] {
        [
            "id": requestID,
            "cmd": "detach-attached-view",
            "surface": surfaceID,
            "view": view,
        ]
    }

    /// Replaces a terminal's sizing policy on the host.
    public func setSizePolicy(surfaceID: UInt64, policy: TerminalSizingPolicy, requestID: UInt64 = 1) -> [String: Any] {
        [
            "id": requestID,
            "cmd": "set-size-policy",
            "surface": surfaceID,
            "policy": jsonObject(policy) ?? ["mode": policy.mode.rawValue],
        ]
    }

    /// Sets or clears one participant's counts override.
    ///
    /// - Parameters:
    ///   - surfaceID: the numeric cmux-tui surface.
    ///   - target: `lease`, `view` or `participant` and its value.
    ///   - counts: `true`, `false` or `nil` to clear.
    ///   - requestID: correlation id.
    public func setSizeCounts(
        surfaceID: UInt64,
        target: (key: String, value: String),
        counts: Bool?,
        requestID: UInt64 = 1
    ) -> [String: Any] {
        [
            "id": requestID,
            "cmd": "set-size-counts",
            "surface": surfaceID,
            target.key: target.value,
            "counts": counts.map { $0 as Any } ?? NSNull(),
        ]
    }

    /// Asks for the current size state.
    public func getSizeState(surfaceID: UInt64, requestID: UInt64 = 1) -> [String: Any] {
        [
            "id": requestID,
            "cmd": "get-size-state",
            "surface": surfaceID,
        ]
    }

    /// Disconnects one participant (by host participant id) on behalf of `by`.
    public func detachClient(participantID: String, by actor: TerminalDetachActor, requestID: UInt64 = 1) -> [String: Any] {
        [
            "id": requestID,
            "cmd": "detach-client",
            "client": participantID,
            "by": jsonObject(actor) ?? [:],
        ]
    }

    private func identityObject(_ identity: TerminalSizingParticipant) -> [String: Any] {
        [
            "user_id": identity.userID as Any? ?? NSNull(),
            "display_name": identity.displayName as Any? ?? NSNull(),
            "device_kind": identity.deviceKind.rawValue,
            "device_name": identity.deviceName as Any? ?? NSNull(),
        ]
    }

    private func jsonObject<T: Encodable>(_ value: T) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Claims this connection as the terminal's geometry owner.
    ///
    /// A `resize-surface` report is sent before this command.  The daemon
    /// requires a reported size before it can promote a client, and the
    /// explicit claim is what makes a native pane's grid authoritative rather
    /// than merely a passive viewport hint.
    public func claimGeometry(surfaceID: UInt64, requestID: UInt64 = 1) -> [String: Any] {
        [
            "id": requestID,
            "cmd": "set-client-sizing",
            "surface": surfaceID,
            "enabled": true,
            "exclusive": true,
        ]
    }

    /// Opens a byte attach stream for one numeric cmux-tui surface.
    public func attach(
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

    /// Writes raw input bytes to the remote PTY. Input asks for no reply, so a
    /// relay can carry it as compact one-way input.
    public func input(surfaceID: UInt64, bytes: Data, requestID: UInt64 = 1) -> [String: Any] {
        [
            "id": requestID,
            "cmd": "send",
            "surface": surfaceID,
            "bytes": bytes.base64EncodedString(),
            "no_reply": true,
        ]
    }

    /// Sends one semantic key chord through the remote terminal's key encoder.
    public func namedKey(surfaceID: UInt64, key: String, requestID: UInt64 = 1) -> [String: Any] {
        [
            "id": requestID,
            "cmd": "send-key",
            "surface": surfaceID,
            "keys": [key],
        ]
    }

    /// Reports the native pane's current cell grid to the remote PTY.
    public func resize(surfaceID: UInt64, columns: Int, rows: Int, requestID: UInt64 = 1) -> [String: Any] {
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
    public func resizeAttachedView(
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
    public func releaseSizing(surfaceID: UInt64, requestID: UInt64 = 0) -> [String: Any] {
        [
            "id": requestID,
            "cmd": "release-surface-size",
            "surface": surfaceID,
        ]
    }

    /// Removes this exact attach stream's size contribution while retaining
    /// the stream for cached output. The server treats a repeated release as
    /// an idempotent no-op for the same lease.
    public func releaseAttachedViewSize(
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
    public func detach(surfaceID: UInt64, requestID: UInt64 = 1) -> [String: Any] {
        [
            "id": requestID,
            "cmd": "detach-surface",
            "surface": surfaceID,
        ]
    }

    /// Retires a capability-negotiated attachment while keeping the control
    /// socket usable for any other future view.
    public func detachAttachedView(
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
    public func line(_ command: [String: Any]) -> Data? {
        guard let data = try? JSONSerialization.data(withJSONObject: command) else { return nil }
        return data + Data([0x0A])
    }
}

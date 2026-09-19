import Foundation

/// Builds private transport commands for a native Cloud Ghostty byte mirror.
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

    /// A round trip that proves the control connection is alive. Every daemon
    /// answers it; the watchdog sends it when an attached stream has carried
    /// no frame for a while.
    func ping(requestID: UInt64 = 1) -> [String: Any] {
        [
            "id": requestID,
            "cmd": "ping",
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
                "terminal-color-overrides-v1",
            ],
        ]
    }

    /// The capability under which the daemon fans out collaboration
    /// pointers and highlights (`cmux-tui/spec/presence.md`).
    let presenceCapability = "presence-v1"

    /// Advertises a presence-only connection: it never attaches a surface.
    func setPresenceClientInfo(name: String, kind: String, requestID: UInt64) -> [String: Any] {
        [
            "id": requestID,
            "cmd": "set-client-info",
            "name": name,
            "kind": kind,
            "capabilities": [presenceCapability],
        ]
    }

    /// Subscribes to `presence-changed` and nothing else.
    func subscribePresence(requestID: UInt64) -> [String: Any] {
        ["id": requestID, "cmd": "subscribe", "presence_only": true]
    }

    /// Reads the requesting connection's opaque client id after the handshake.
    func listClients(requestID: UInt64) -> [String: Any] {
        ["id": requestID, "cmd": "list-clients"]
    }

    /// Asks for every live pointer so a late joiner can draw them.
    func presenceList(requestID: UInt64) -> [String: Any] {
        ["id": requestID, "cmd": "presence-list"]
    }

    /// Publishes this connection's pointer and highlight on one surface.
    func presenceUpdate(
        surfaceID: UInt64,
        pointer: CloudPresenceAnchor?,
        highlight: CloudPresenceHighlight?,
        requestID: UInt64
    ) -> [String: Any] {
        var command: [String: Any] = ["id": requestID, "cmd": "presence-update", "surface": surfaceID]
        if let pointer { command["pointer"] = pointer.json }
        if let highlight { command["highlight"] = highlight.json }
        return command
    }

    /// Withdraws this connection's presence.
    func presenceClear(requestID: UInt64) -> [String: Any] {
        ["id": requestID, "cmd": "presence-clear"]
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

    /// Builds the schema-generated identify command.
    func typedIdentify(requestID: UInt64 = 1) -> CloudTuiGenerated.Command {
        .identify(id: requestID, request: .init())
    }

    /// Builds the schema-generated ping command.
    func typedPing(requestID: UInt64 = 1) -> CloudTuiGenerated.Command {
        .ping(id: requestID, request: .init())
    }

    /// Builds the schema-generated client-info command.
    func typedClientInfo(name: String, kind: String, capabilities: [String], requestID: UInt64) -> CloudTuiGenerated.Command {
        .setClientInfo(
            id: requestID,
            request: .init(
                capabilities: .value(capabilities),
                kind: .value(kind),
                name: .value(name)
            )
        )
    }

    /// Builds the schema-generated presence-only subscription.
    func typedPresenceSubscribe(requestID: UInt64) -> CloudTuiGenerated.Command {
        .subscribe(id: requestID, request: .init(presenceOnly: .value(true)))
    }

    /// Builds the schema-generated presence list command.
    func typedPresenceList(requestID: UInt64) -> CloudTuiGenerated.Command {
        .presenceList(id: requestID, request: .init())
    }

    /// Builds the schema-generated presence clear command.
    func typedPresenceClear(requestID: UInt64) -> CloudTuiGenerated.Command {
        .presenceClear(id: requestID, request: .init())
    }

    /// Builds the schema-generated presence update command.
    func typedPresenceUpdate(
        surfaceID: UInt64,
        pointer: CloudPresenceAnchor?,
        highlight: CloudPresenceHighlight?,
        requestID: UInt64
    ) -> CloudTuiGenerated.Command {
        .presenceUpdate(
            id: requestID,
            request: .init(
                highlight: highlight.map(CloudTuiGenerated.OptionalField.value) ?? .missing,
                pointer: pointer.map(CloudTuiGenerated.OptionalField.value) ?? .missing,
                surface: surfaceID
            )
        )
    }

    /// Builds the schema-generated byte attachment command.
    func typedAttach(
        surfaceID: UInt64,
        columns: Int? = nil,
        rows: Int? = nil,
        expectedGeneration: String? = nil,
        expectedTerminalID: String? = nil,
        requestID: UInt64 = 1
    ) -> CloudTuiGenerated.Command? {
        let initialColumns = columns.map { UInt16(clamping: $0) }
        let initialRows = rows.map { UInt16(clamping: $0) }
        guard (columns == nil) == (rows == nil),
              (columns == nil || (columns ?? 0) > 0 && (rows ?? 0) > 0),
              (expectedGeneration == nil) == (expectedTerminalID == nil) else { return nil }
        return .attachSurface(
            id: requestID,
            request: .init(
                cols: initialColumns.map(CloudTuiGenerated.OptionalField.value) ?? .missing,
                expectedGeneration: expectedGeneration.map(CloudTuiGenerated.OptionalField.value) ?? .missing,
                expectedTerminalId: expectedTerminalID.map(CloudTuiGenerated.OptionalField.value) ?? .missing,
                mode: .missing,
                rows: initialRows.map(CloudTuiGenerated.OptionalField.value) ?? .missing,
                surface: surfaceID == 0 ? .missing : .value(surfaceID)
            )
        )
    }

    /// Builds a raw-byte input command.
    func typedInput(surfaceID: UInt64, bytes: Data, requestID: UInt64 = 1) -> CloudTuiGenerated.Command {
        .send(id: requestID, request: .init(bytes: .value(bytes.base64EncodedString()), surface: surfaceID))
    }

    /// Builds a semantic key chord command.
    func typedNamedKey(surfaceID: UInt64, key: String, requestID: UInt64 = 1) -> CloudTuiGenerated.Command {
        .sendKey(id: requestID, request: .init(keys: [key], surface: surfaceID))
    }

    /// Builds a legacy surface resize command.
    func typedResize(surfaceID: UInt64, columns: Int, rows: Int, requestID: UInt64 = 1) -> CloudTuiGenerated.Command {
        .resizeSurface(id: requestID, request: .init(cols: UInt16(clamping: columns), rows: UInt16(clamping: rows), surface: surfaceID))
    }

    /// Builds a lease-fenced resize command.
    func typedResizeAttachedView(surfaceID: UInt64, lease: String, columns: Int, rows: Int, requestID: UInt64 = 1) -> CloudTuiGenerated.Command? {
        guard !lease.isEmpty, (1...maximumGridDimension).contains(columns), (1...maximumGridDimension).contains(rows) else { return nil }
        return .resizeAttachedView(id: requestID, request: .init(cols: UInt16(columns), lease: lease, rows: UInt16(rows), surface: surfaceID))
    }

    /// Builds the legacy sizing release command.
    func typedReleaseSizing(surfaceID: UInt64, requestID: UInt64 = 0) -> CloudTuiGenerated.Command {
        .releaseSurfaceSize(id: requestID, request: .init(surface: surfaceID))
    }

    /// Builds a lease-fenced sizing release command.
    func typedReleaseAttachedViewSize(surfaceID: UInt64, lease: String, requestID: UInt64 = 0) -> CloudTuiGenerated.Command? {
        guard !lease.isEmpty else { return nil }
        return .releaseAttachedViewSize(id: requestID, request: .init(lease: lease, surface: surfaceID))
    }

    /// Builds a lease-fenced attachment detach command.
    func typedDetachAttachedView(surfaceID: UInt64, lease: String, requestID: UInt64 = 1) -> CloudTuiGenerated.Command {
        .detachAttachedView(id: requestID, request: .init(lease: lease, surface: surfaceID))
    }

    /// Builds an exclusive geometry claim.
    func typedClaimGeometry(surfaceID: UInt64, requestID: UInt64 = 1) -> CloudTuiGenerated.Command {
        .setClientSizing(id: requestID, request: .init(enabled: true, exclusive: .value(true), surface: surfaceID))
    }

    /// Builds one image-paste operation from the protocol's optional chunk fields.
    func typedPasteImage(
        terminalID: String,
        lease: String,
        uploadID: String,
        surfaceID: UInt64,
        operation: String,
        mime: String? = nil,
        data: String? = nil,
        size: UInt64? = nil,
        offset: UInt64? = nil,
        requestID: UInt64
    ) -> CloudTuiGenerated.Command {
        .pasteImage(
            id: requestID,
            request: .init(
                data: data.map(CloudTuiGenerated.OptionalField.value) ?? .missing,
                lease: lease,
                mime: mime.map(CloudTuiGenerated.OptionalField.value) ?? .missing,
                offset: offset.map(CloudTuiGenerated.OptionalField.value) ?? .missing,
                op: operation,
                size: size.map(CloudTuiGenerated.OptionalField.value) ?? .missing,
                surface: surfaceID,
                terminalId: terminalID,
                uploadId: uploadID
            )
        )
    }

    /// Serializes a schema-generated command as one newline-delimited message.
    func line(_ command: CloudTuiGenerated.Command) -> Data? {
        try? command.line()
    }

    /// Serializes a legacy dictionary command during the remaining transport migration.
    func line(_ command: [String: Any]) -> Data? {
        guard let data = try? JSONSerialization.data(withJSONObject: command) else { return nil }
        return data + Data([0x0A])
    }
}
